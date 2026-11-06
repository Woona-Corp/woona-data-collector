"""Host-side CFR30 preparation; capture artifacts are never rewritten.

Requires the host's ffmpeg/ffprobe and (for discovery) Docker, not new API dependencies.
The label worker consumes the verified registry read-only.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
import shlex
import shutil
import subprocess
import time
import uuid
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path

from server.video_presentation import is_cfr30

FPS = 30


def encoder_recipe(preset, crf):
    return {'codec': 'libx264', 'preset': preset, 'crf': crf, 'maxrate_kbps': 12000}


def prepared(root, row, item, preset, crf):
    """Cheap periodic admission: immutable source identity plus verified output stat.

    Full hashes are checked when encoding/reusing a file and again by dataset export.
    """
    if not is_cfr30(item):
        return False
    if (item.get('source_artifact_id') != str(row['id']) or item.get('source_sha256') != row['sha256']
            or item.get('encoder') != encoder_recipe(preset, crf)):
        return False
    try:
        source = local_file(root, row['server_relative_path'])
        output = local_file(root, item['relative_path'])
        return (output.is_relative_to(Path(root).resolve() / 'derived' / 'cfr30')
                and source.stat().st_size == row['expected_size_bytes']
                and output.stat().st_size == item['size_bytes'])
    except (OSError, ValueError, KeyError):
        return False


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def local_file(root, relative):
    if not isinstance(relative, str) or Path(relative).is_absolute():
        raise ValueError('Expected a storage-relative file')
    path = (Path(root).resolve() / relative).resolve()
    if not path.is_relative_to(Path(root).resolve()) or not path.is_file():
        raise ValueError('Missing file or path outside storage')
    return path


def probe(path):
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format',
                             '-of', 'json', str(path)], capture_output=True, text=True,
                            timeout=120, check=True)
    metadata = json.loads(result.stdout)
    video = next(s for s in metadata['streams'] if s['codec_type'] == 'video')
    duration = float(video['duration'])
    start = float(video.get('start_time', 0)) - float(metadata['format'].get('start_time', 0))
    if not math.isfinite(duration) or duration <= 0 or not math.isfinite(start):
        raise ValueError('Invalid video timing')
    return metadata, video, duration, start


def packet_grid(path, video=None):
    """Check every presentation timestamp, including streams with reordered B frames."""
    if video is None:
        _, video, _, _ = probe(path)
    result = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                             '-show_entries', 'packet=pts', '-of', 'csv=p=0', str(path)],
                            capture_output=True, text=True, timeout=180, check=True)
    pts = sorted(int(line.strip().split(',')[0]) for line in result.stdout.splitlines() if line.strip())
    if not pts or len(pts) != len(set(pts)):
        raise ValueError('Missing or duplicate video presentation timestamps')
    tb = Fraction(video['time_base'])
    first = pts[0] * float(tb)
    maximum = max(abs((p - pts[0]) * float(tb) - i / FPS) for i, p in enumerate(pts))
    return {'frames': len(pts), 'first_pts_seconds': first,
            'last_pts_seconds': pts[-1] * float(tb), 'grid_error_seconds': maximum,
            'cfr30': maximum <= max(float(tb) * 1.01, 1e-6)
                     and Fraction(video['avg_frame_rate']) == FPS}


def discover(container):
    query = """BEGIN READ ONLY;
        SELECT coalesce(json_agg(a),'[]') FROM (
          SELECT id, recording_id, server_relative_path, sha256, expected_size_bytes
          FROM artifacts WHERE artifact_type='video' AND storage_status='available'
          ORDER BY recording_id) a; COMMIT;"""
    command = ('psql -XAtq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c '
               + shlex.quote(query))
    rows = json.loads(subprocess.check_output(['docker', 'exec', container, 'sh', '-c', command], text=True))
    if len({r['recording_id'] for r in rows}) != len(rows):
        raise ValueError('Multiple available video artifacts for one recording')
    return rows


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_name(path.name + '.pending')
    with pending.open('w') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    pending.replace(path)


def audit(root, rows, output):
    findings = []
    for row in rows:
        source = local_file(root, row['server_relative_path'])
        metadata, video, duration, start = probe(source)
        grid = packet_grid(source, video)
        record = {**row, 'duration_seconds': duration, 'video_start_seconds': start,
                  'width': video['width'], 'height': video['height'],
                  'avg_frame_rate': video['avg_frame_rate'], **grid,
                  'audio': [{k: s.get(k) for k in ['codec_name', 'duration', 'start_time', 'nb_frames', 'channels']}
                            for s in metadata['streams'] if s['codec_type'] == 'audio']}
        findings.append(record)
        atomic_json(output, {'audited_at_utc': datetime.now(timezone.utc).isoformat(), 'videos': findings})
        print(json.dumps({k: record[k] for k in ['recording_id', 'duration_seconds', 'avg_frame_rate', 'cfr30', 'grid_error_seconds', 'video_start_seconds']}), flush=True)
    return findings


def normalize_one(root, row, registry, *, threads=3, preset='ultrafast', crf=18):
    root = Path(root).resolve()
    recording = str(uuid.UUID(str(row['recording_id'])))
    source = local_file(root, row['server_relative_path'])
    if source.stat().st_size != row['expected_size_bytes'] or sha256(source) != row['sha256']:
        raise ValueError('Source artifact checksum/size mismatch')
    prior = registry.get('entries', {}).get(recording)
    if prepared(root, row, prior, preset, crf):
        path = local_file(root, prior['relative_path'])
        if sha256(path) == prior['sha256']:
            return prior
    # Legacy orientation-only presentations corrected erroneous display matrices.
    # Carry this explicit correction forward instead of reintroducing the original matrix.
    rotation = prior.get('source_rotation_override', prior.get('rotation_degrees')) if prior else None
    metadata, video, duration, start = probe(source)
    if abs(start) > 1e-4:
        raise ValueError('Nonzero first video offset needs an explicit time mapping')
    output = root / 'derived' / 'cfr30' / (recording + '.mp4')
    output.parent.mkdir(parents=True, exist_ok=True)
    pending = output.with_suffix('.pending.mp4')
    frames = math.ceil(duration * FPS - 1e-6)
    target_duration = frames / FPS
    if shutil.disk_usage(root).free < 10_000_000_000 + target_duration * 1_500_000:
        raise ValueError('Insufficient free space for a verified working copy')
    progress = pending.with_suffix('.progress')
    command = ['nice', '-n', '15', 'ffmpeg', '-v', 'error', '-nostdin', '-y', '-threads', str(threads)]
    if rotation is not None:
        command += ['-noautorotate', '-display_rotation', str(rotation)]
    command += ['-copyts', '-start_at_zero', '-i', str(source), '-map', '0:v:0']
    audio = [s for s in metadata['streams'] if s['codec_type'] == 'audio' and s.get('codec_name')]
    for stream in audio:
        command += ['-map', '0:' + str(stream['index'])]
    command += ['-vf', f'fps=fps=30:start_time=0:round=near:eof_action=pass,tpad=stop_mode=clone:stop_duration=0.034,trim=end_frame={frames}',
                '-c:v', 'libx264', '-preset', preset, '-crf', str(crf), '-pix_fmt', 'yuv420p',
                '-threads', str(threads), '-maxrate', '12000k', '-bufsize', '24000k', '-progress', str(progress), '-stats_period', '30', '-fps_mode', 'cfr', '-video_track_timescale', '90000',
                '-c:a', 'copy', '-t', str(target_duration), '-avoid_negative_ts', 'disabled',
                '-metadata:s:v:0', 'rotate=0', '-movflags', '+faststart', str(pending)]
    started = time.monotonic()
    subprocess.run(command, check=True)
    out_metadata, out_video, out_duration, out_start = probe(pending)
    out_audio = [s for s in out_metadata['streams'] if s['codec_type'] == 'audio']
    if len(out_audio) != len(audio) or any(
            original['codec_name'] != converted['codec_name']
            or abs(float(original.get('start_time', 0)) - float(converted.get('start_time', 0))) > .001
            for original, converted in zip(audio, out_audio)):
        raise ValueError('Audio streams or initial timing changed')
    grid = packet_grid(pending, out_video)
    if (not grid['cfr30'] or grid['frames'] != frames or abs(out_start) > 1e-6
            or abs(out_duration - target_duration) > 1e-4
            or not -1e-4 <= out_duration - duration <= 1 / FPS + 1e-4):
        raise ValueError('CFR output failed complete timestamp/duration verification')
    # Packet inspection does not decode H.264. The encode itself decoded the complete source;
    # a separate full decode validates the finalized output before registry admission.
    subprocess.run(['nice', '-n', '15', 'ffmpeg', '-v', 'error', '-xerror', '-threads', str(threads),
                    '-i', str(pending), '-map', '0:v:0', '-fps_mode', 'passthrough', '-f', 'null', '-'], check=True)
    if sha256(source) != row['sha256']:
        raise ValueError('Source changed during normalization')
    item = dict(source_artifact_id=str(row['id']), source_sha256=row['sha256'],
                source_relative_path=row['server_relative_path'],
                relative_path=output.relative_to(root).as_posix(), sha256=sha256(pending),
                size_bytes=pending.stat().st_size, transform='cfr30', frame_rate=FPS,
                frame_count=frames, source_duration_seconds=duration, duration_seconds=out_duration,
                time_mapping={'scale': 1, 'offset_seconds': 0, 'max_error_seconds': 1 / FPS},
                grid_error_seconds=grid['grid_error_seconds'], source_rotation_override=rotation,
                video_start_seconds=out_start, audio_streams=len(audio),
                discarded_empty_audio_streams=sum(s['codec_type'] == 'audio' for s in metadata['streams']) - len(audio),
                encoder=encoder_recipe(preset, crf),
                verified_at_utc=datetime.now(timezone.utc).isoformat(),
                processing_seconds=time.monotonic()-started)
    pending.replace(output)
    progress.unlink(missing_ok=True)
    return item


def prepare(root, rows, registry_path, *, threads=3, preset='ultrafast', crf=18):
    registry_path = Path(registry_path)
    lock = Path(root) / 'derived' / 'video-normalization.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open('w') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        registry = json.loads(registry_path.read_text()) if registry_path.exists() else {'schema_version': 2, 'entries': {}}
        if registry.get('schema_version') not in (1, 2):
            raise ValueError('Unsupported registry')
        registry['schema_version'] = 2
        failed = []
        for row in rows:
            if prepared(root, row, registry['entries'].get(str(row['recording_id'])), preset, crf):
                continue
            try:
                item = normalize_one(root, row, registry, threads=threads, preset=preset, crf=crf)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                failed.append(row['recording_id'])
                print(json.dumps({'recording_id': row['recording_id'], 'error': str(error)}), flush=True)
                for suffix in ('.pending.mp4', '.pending.progress'):
                    (Path(root) / 'derived' / 'cfr30' / (str(uuid.UUID(row['recording_id'])) + suffix)).unlink(missing_ok=True)
                continue
            registry['entries'][str(row['recording_id'])] = item
            atomic_json(registry_path, registry)
            print(json.dumps({'recording_id': row['recording_id'], 'frame_count': item['frame_count'],
                              'processing_seconds': item['processing_seconds'], 'size_bytes': item['size_bytes']}), flush=True)
        if failed:
            raise ValueError(f'Normalization failed for {len(failed)} recordings; inspect the service journal')
        return registry


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--postgres-container', default='shared-postgres-1')
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--audit', type=Path)
    mode.add_argument('--prepare', type=Path, help='Candidate or active registry; does not change Label Studio')
    p.add_argument('--threads', type=int, default=3)
    p.add_argument('--preset', choices=['ultrafast','superfast','veryfast','fast'], default='ultrafast')
    p.add_argument('--crf', type=int, default=18)
    args = p.parse_args()
    if not 1 <= args.threads <= 8 or not 0 <= args.crf <= 30:
        p.error('Invalid resource/quality limit')
    rows = sorted(discover(args.postgres_container), key=lambda row: row['expected_size_bytes'])
    if args.audit:
        audit(args.root, rows, args.audit)
    else:
        prepare(args.root, rows, args.prepare, threads=args.threads, preset=args.preset, crf=args.crf)
