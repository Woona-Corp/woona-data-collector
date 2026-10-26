"""Read-only identity review. This tool cannot apply a split or rewrite provenance."""
import json
import os
from collections import defaultdict


def build_review(dogs, versions, recordings, external_ids):
    by_dog = defaultdict(list)
    for version in versions:
        by_dog[str(version['dog_id'])].append(version)
    result = []
    for dog in dogs:
        dog_id = str(dog['id'])
        identities = defaultdict(list)
        for version in by_dog[dog_id]:
            identity = (version.get('animal_id') or '').strip().casefold()
            if identity:
                identities[identity].append(version)
        if len(identities) < 2:
            continue
        groups = []
        for identity, history in sorted(identities.items()):
            version_ids = {str(v['id']) for v in history}
            names = sorted({v.get('name_at_version') for v in history if v.get('name_at_version')})
            candidates = [str(other['id']) for other in dogs if str(other['id']) != dog_id and
                          other['number_or_name'].strip().casefold() in {n.strip().casefold() for n in names}]
            groups.append({'animal_id': identity, 'historical_names': names,
                'profile_version_ids': sorted(version_ids),
                'recording_ids': sorted(str(r['id']) for r in recordings
                    if str(r['dog_profile_version_id']) in version_ids),
                'same_name_candidates_for_review_only': candidates})
        result.append({'dog_id': dog_id, 'current_name': dog['number_or_name'],
            'account_id': dog.get('account_id'), 'identities': groups,
            'reserved_external_ids': sorted(e['external_id'] for e in external_ids if str(e['dog_id']) == dog_id),
            'requires_operator_confirmation': True,
            'acceptance_checks': ['local exports preserved', 'physical animal confirmed per recording',
                'canonical mapping and accounts approved', 'old client upload remains idempotent',
                'restore keeps provenance and immutable versions', 'receipts and source hashes preserved']})
    return {'mode': 'read-only review', 'apply_supported': False, 'review_groups': result}


def main():
    from sqlalchemy import create_engine, text
    engine = create_engine(os.environ['DATABASE_URL'])
    with engine.connect() as connection:
        connection.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY'))
        def rows(sql): return [dict(row) for row in connection.execute(text(sql)).mappings()]
        report = build_review(rows('SELECT id,number_or_name,account_id FROM dogs'),
            rows("SELECT id,dog_id,questionnaire->>'animalId' AS animal_id,questionnaire->>'numberOrName' AS name_at_version FROM dog_profile_versions"),
            rows('SELECT id,dog_profile_version_id FROM recordings'),
            rows('SELECT dog_id,external_id FROM dog_external_ids'))
        connection.rollback()
    engine.dispose()
    print(json.dumps(report, default=str, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
