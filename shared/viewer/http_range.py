from __future__ import annotations

import re


def parse_byte_range(range_header: str, size: int) -> tuple[int, int]:
    """Parse one RFC 7233-style explicit byte range.

    The viewer intentionally supports only a single start-end or open-ended
    range because browser video playback does not require multipart ranges.
    """
    if size < 0:
        raise ValueError("invalid_size")

    match = re.fullmatch(r"bytes=(\d+)-(\d*)", range_header)
    if match is None:
        raise ValueError("invalid_range")

    start = int(match.group(1))
    end = int(match.group(2)) if match.group(2) else size - 1

    if start >= size or end < start or end >= size:
        raise ValueError("range_not_satisfiable")

    return start, end
