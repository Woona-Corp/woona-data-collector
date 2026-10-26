"""Shared activity admission rules for labeling and the operator dashboard."""
REQUIRED_ACTIVITY_ARTIFACTS = frozenset({'packet', 'packet_timeline', 'raw', 'diagnostic', 'sync', 'video'})


def activity_exclusion_reasons(ingest_status, capture_status, capture_error_code, questionnaire, available_kinds):
    reasons = []
    if ingest_status != 'complete':
        reasons.append('Загрузка не завершена')
    if capture_status != 'completed':
        reasons.append('Запись прервана или завершилась ошибкой')
    if capture_error_code:
        reasons.append('Ошибка захвата: ' + str(capture_error_code))
    if questionnaire.get('sessionKind') == 'heart':
        reasons.append('Сессия сердцебиения: хранение вне проекта активности')
    if questionnaire.get('schemaVersion') != 2:
        reasons.append('Анкета старого формата')
    if not set(questionnaire.get('plannedActivities') or []) & {'Аллюр/движение', 'Активность'}:
        reasons.append('В плане нет съёмки активности')
    missing = REQUIRED_ACTIVITY_ARTIFACTS - set(available_kinds)
    if missing:
        reasons.append('Недостающие файлы: ' + ', '.join(sorted(missing)))
    return reasons
