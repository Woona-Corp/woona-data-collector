"""Explicit local-operator integrity page with caller-selected bounded resources.

Run inside the API container. This command does not copy files, create backups,
modify recordings, or start background work. HTTP cannot opt into this budget.
"""
import argparse
import json
import uuid

from server.integrity_audit import integrity_page


def positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError('A positive integer is required')
    return number


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group(required=True)
    scope.add_argument('--account')
    scope.add_argument('--unassigned', action='store_true')
    parser.add_argument('--cursor', type=uuid.UUID)
    parser.add_argument('--max-bytes', type=positive, default=256 * 1024 ** 2,
                        help='Maximum bytes hashed during this explicit invocation')
    parser.add_argument('--max-seconds', type=positive, default=60)
    parser.add_argument('--limit', type=positive, default=50)
    parsed = parser.parse_args(argv)
    if parsed.limit > 100 or parsed.max_seconds > 3600 or parsed.max_bytes >= 2 ** 63:
        parser.error('Maximum page size is 100, duration 3600 seconds, bytes must fit signed 64-bit')
    return parsed


def main(argv=None):
    args = arguments(argv)
    from server.app import STORAGE_ROOT, engine, normalize_account
    account = normalize_account(args.account) if args.account is not None else None
    policy = {'maxArtifacts': args.limit, 'maxFileBytes': args.max_bytes,
              'maxHashBytes': args.max_bytes, 'maxSeconds': args.max_seconds,
              'minimumIntervalSeconds': 1}
    with engine.begin() as connection:
        result = integrity_page(connection, STORAGE_ROOT, account, limit=args.limit,
                                cursor=args.cursor, policy=policy)
    print(json.dumps(result, default=str))
    return 1 if result['problems'] else 0 if result['coverage']['scopeChecksumVerified'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
