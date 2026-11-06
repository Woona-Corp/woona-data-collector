"""Explicit LS timeline migration. Run inside Label Studio with its Django settings.

Only mutable annotation coordinates and working-video pointers change. The journal
contains exact before/after images of the changed fields, not a database dump.
Stop the labeling web process and label_sync during --apply (keep PostgreSQL up).
"""
from __future__ import annotations

import argparse
from copy import deepcopy
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
from urllib.parse import quote
from xml.etree import ElementTree as ET

if __package__:
    from .video_presentation import FRAME_RATE, is_cfr30
else:  # LS itself has a server.py; direct execution avoids that module collision.
    from video_presentation import FRAME_RATE, is_cfr30

MIGRATION = 'video-cfr30-v1'


def nearest(value):
    return (2 * value.numerator + value.denominator) // (2 * value.denominator)


def convert_result(value, old_fps, timeline, video):
    """Visit results and nested prediction snapshots, preserving all noncoordinates."""
    ratio = Fraction(FRAME_RATE, old_fps)
    result = deepcopy(value)

    def visit(node):
        if isinstance(node, list):
            for child in node:
                visit(child)
        elif isinstance(node, dict):
            if node.get('type') == 'timelinelabels':
                if node.get('from_name') != timeline or node.get('to_name') != video:
                    raise ValueError('Unexpected timeline control')
                for span in node['value']['ranges']:
                    start, end = span['start'], span['end']
                    if type(start) is not int or type(end) is not int or not 1 <= start <= end:
                        raise ValueError('Invalid one-based inclusive interval')
                    new_start, new_end = nearest((start - 1) * ratio) + 1, nearest(end * ratio)
                    if new_start > new_end:
                        raise ValueError('Interval would collapse')
                    for before, after in [(start - 1, new_start - 1), (end, new_end)]:
                        if abs(Fraction(before, old_fps) - Fraction(after, FRAME_RATE)) > Fraction(1, 2 * FRAME_RATE):
                            raise ValueError('Interval time changed beyond half a new frame')
                    span.update(start=new_start, end=new_end)
            else:
                if 'ranges' in node:
                    raise ValueError('Unrecognized frame coordinates')
                for child in node.values():
                    visit(child)

    visit(result)
    return result


def config30(config):
    root = ET.fromstring(config)
    videos, timelines = root.findall('.//Video'), root.findall('.//TimelineLabels')
    if len(videos) != 1 or len(timelines) != 1 or timelines[0].get('toName') != videos[0].get('name'):
        raise ValueError('Expected one video timeline')
    rate = videos[0].get('frameRate', videos[0].get('framerate', '24'))
    if rate not in ('24', '30'):
        raise ValueError('Only reviewed 24-to-30 migration is supported')
    # Keep every other byte of the config (including comments and styles).
    if rate == '30':
        return config, 30, timelines[0].get('name'), videos[0].get('name')
    import re
    tag = re.search(r'<Video\b[^>]*>', config)
    if not tag:
        raise ValueError('Missing Video tag')
    updated, count = re.subn(r'\b(?:frameRate|framerate)\s*=\s*([\"\'])24\1', 'frameRate="30"', tag[0])
    if not count:
        updated = tag[0].replace('<Video', '<Video frameRate="30"', 1)
    new_config = config[:tag.start()] + updated + config[tag.end():]
    if ET.fromstring(new_config).find('.//Video').get('frameRate') != '30':
        raise ValueError('Config update failed')
    return new_config, 24, timelines[0].get('name'), videos[0].get('name')


def write_journal(path, value):
    pending = path.with_suffix('.pending')
    with pending.open('w') as stream:
        os.chmod(pending, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(path)


def locked_models(connection):
    from projects.models import Project
    from tasks.models import Task, Annotation, AnnotationDraft, Prediction, TaskLock
    models = [Project, Task, Annotation, AnnotationDraft, Prediction, TaskLock]
    with connection.cursor() as cursor:
        cursor.execute("SET LOCAL lock_timeout = '5s'")
        for model in models:
            cursor.execute('LOCK TABLE ' + connection.ops.quote_name(model._meta.db_table) + ' IN EXCLUSIVE MODE')
    return {m._meta.label: m for m in models}


def rollback(journal_path):
    from django.db import connection, transaction
    journal_path = Path(journal_path)
    journal = json.loads(journal_path.read_text())
    if journal.get('migration') != MIGRATION or journal.get('state') not in ('planned', 'committed'):
        raise ValueError('Unexpected rollback journal')
    with transaction.atomic():
        models = locked_models(connection)
        for change in journal['edits']:
            actual = models[change['model']].objects.values(*change['after']).get(pk=change['id'])
            if actual != change['after']:
                raise ValueError('Rows changed since migration; refusing to discard new edits')
        for change in reversed(journal['edits']):
            models[change['model']].objects.filter(pk=change['id']).update(**change['before'])
        transaction.on_commit(lambda: write_journal(journal_path, {**journal, 'state': 'rolled_back'}))
    return {'status': 'rolled_back', 'edits': len(journal['edits'])}


def migrate(project_id, registry_path, storage, journal_path, apply=False):
    # Imports stay here so pure coordinate rules are testable without Django.
    from django.db import connection, transaction
    from django.db.models import Q
    from django.utils import timezone as django_timezone
    from projects.models import Project, parse_config, extract_data_types
    from tasks.models import Task, Annotation, AnnotationDraft, Prediction, TaskLock

    registry = json.loads(Path(registry_path).read_text())
    storage, journal_path = Path(storage).resolve(), Path(journal_path)
    with transaction.atomic():
        # Table locks also cover inserts/drafts that do not hold a task row lock.
        models = locked_models(connection)
        project = Project.objects.get(pk=project_id)
        if TaskLock.objects.filter(task__project_id=project_id, expire_at__gt=django_timezone.now()).exists():
            raise ValueError('Active annotation session; migration refused')
        config, old_fps, timeline, video = config30(project.label_config)
        tasks = list(Task.objects.filter(project_id=project_id).order_by('pk'))
        if old_fps == FRAME_RATE:
            if not tasks or not all((t.meta or {}).get('annotation_coordinates', {}).get('frame_rate') == 30
                                    and is_cfr30((t.meta or {}).get('video_presentation')) for t in tasks):
                raise ValueError('Partially migrated project; manual review required')
            return {'status': 'already_migrated', 'tasks': len(tasks)}
        edits = []

        def edit(model, row, after):
            before = {key: deepcopy(getattr(row, key)) for key in after}
            edits.append({'model': model._meta.label, 'id': row.pk, 'before': before, 'after': after})

        for task in tasks:
            data, meta = deepcopy(task.data), deepcopy(task.meta or {})
            frozen = meta.get('annotation_coordinates', {})
            if frozen.get('frame_rate', old_fps) != old_fps or frozen.get('frame_origin', 1) != 1 or frozen.get('end_inclusive', True) is not True:
                raise ValueError('Unexpected frozen task coordinates')
            rid = data.get('recording_id')
            item = registry['entries'].get(rid)
            if not is_cfr30(item):
                raise ValueError('Verified CFR30 video required for every task')
            path = (storage / item['relative_path']).resolve()
            if (not path.is_relative_to(storage / 'derived' / 'cfr30') or not path.is_file()
                    or path.stat().st_size != item['size_bytes']):
                raise ValueError('Working video missing or changed')
            current = meta.get('video_presentation')
            original = data.get('original_video', data.get('video'))
            if current and data.get('video') != '/data/local-files/?d=' + quote('woona/' + current['relative_path'], safe='/'):
                raise ValueError('Unexpected current working video')
            expected_original = '/data/local-files/?d=' + quote('woona/' + item['source_relative_path'], safe='/')
            if original != expected_original or (current and any(current.get(key) != item[key] for key in ('source_artifact_id', 'source_sha256'))):
                raise ValueError('Original video identity differs from prepared recording')
            data['original_video'] = original
            data['video'] = '/data/local-files/?d=' + quote('woona/' + item['relative_path'], safe='/')
            meta['video_presentation'] = item
            meta['annotation_coordinates'] = {**frozen, 'frame_rate': 30, 'frame_origin': 1,
                'end_inclusive': True, 'config_sha256': hashlib.sha256(config.encode()).hexdigest(),
                'migration': MIGRATION, 'previous_frame_rate': old_fps, 'endpoint_max_error_seconds': 1 / 60}
            edit(Task, task, {'data': data, 'meta': meta})

        annotations = list(Annotation.objects.filter(task__project_id=project_id).order_by('pk'))
        drafts = list(AnnotationDraft.objects.filter(Q(task__project_id=project_id) | Q(annotation__task__project_id=project_id)).distinct().order_by('pk'))
        predictions = list(Prediction.objects.filter(task__project_id=project_id).order_by('pk'))
        for model, rows, fields in [(Annotation, annotations, ['result', 'prediction']),
                                     (AnnotationDraft, drafts, ['result']), (Prediction, predictions, ['result'])]:
            for row in rows:
                edit(model, row, {key: convert_result(getattr(row, key), old_fps, timeline, video) for key in fields})
        project_fields = {'label_config': config, 'parsed_label_config': parse_config(config),
                          'data_types': extract_data_types(config), 'label_config_hash': hash(str(config))}
        edit(Project, project, project_fields)
        journal = {'migration': MIGRATION, 'project_id': project_id, 'old_fps': old_fps, 'new_fps': 30,
                   'created_at_utc': datetime.now(timezone.utc).isoformat(), 'state': 'planned', 'edits': edits}
        summary = {'status': 'planned', 'tasks': len(tasks), 'annotations': len(annotations),
                   'drafts': len(drafts), 'predictions': len(predictions), 'old_fps': old_fps, 'new_fps': 30}
        if apply:
            if journal_path.exists():
                raise ValueError('Journal already exists; refusing to overwrite migration evidence')
            journal_path.parent.mkdir(parents=True, exist_ok=True)
            write_journal(journal_path, journal)
            for change in edits:
                models[change['model']].objects.filter(pk=change['id']).update(**change['after'])
            for change in edits:
                actual = models[change['model']].objects.values(*change['after']).get(pk=change['id'])
                if actual != change['after']:
                    raise ValueError('Migration write verification failed')
            # If the process dies after commit, the before/after images disambiguate state.
            transaction.on_commit(lambda: write_journal(journal_path, {**journal, 'state': 'committed'}))
            summary['status'] = 'committed'
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=int)
    parser.add_argument('--registry', type=Path)
    parser.add_argument('--storage', type=Path)
    parser.add_argument('--journal', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    if args.rollback and args.apply:
        parser.error('Choose apply or rollback')
    if not args.rollback and not all([args.project, args.registry, args.storage]):
        parser.error('Migration requires project, registry and storage')
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'core.settings.label_studio')
    import django
    django.setup()
    print(json.dumps(rollback(args.journal) if args.rollback else
                     migrate(args.project, args.registry, args.storage, args.journal, args.apply)))
