import SwiftUI
import UIKit

// Display translations never replace questionnaire keys or canonical saved answers.
func questionnaireDisplayText(_ value: String, language: AppLanguage) -> String {
    guard language == .english else { return value }
    if let translated = englishQuestionnaireText[value] { return translated }
    if value.hasPrefix("Максимум "), value.hasSuffix(" символов") {
        return "Maximum " + String(value.dropFirst("Максимум ".count).dropLast(" символов".count)) + " characters"
    }
    if value.hasPrefix("Формат: ") { return "Format: " + String(value.dropFirst("Формат: ".count)) }
    return value
}

let englishQuestionnaireText: [String: String] = [
    "собака": "Dog",
    "Анкета собаки": "Dog questionnaire",
    "ID и кличка обязательны. Неизвестные ответы оставьте пустыми.": "ID and name are required. Leave unknown answers blank.",
    "Номер/ID животного *": "Animal number/ID *",
    "Кличка *": "Name *",
    "Вид": "Species",
    "Приют/лагерь/место сбора": "Shelter/camp/collection site",
    "Порода": "Breed",
    "Если метис — похожая порода/тип": "If mixed breed — similar breed/type",
    "Размер": "Size",
    "мелкий": "Small",
    "средний": "Medium",
    "крупный": "Large",
    "гигантский": "Giant",
    "Возраст, лет": "Age, years",
    "Возраст, месяцев": "Age, months",
    "Источник данных о возрасте": "Age information source",
    "документы": "Documents",
    "со слов владельца/приюта": "Reported by owner/shelter",
    "оценка по зубам": "Dental estimate",
    "неизвестно": "Unknown",
    "Пол": "Sex",
    "самец": "Male",
    "самка": "Female",
    "Стерилизован/кастрирован": "Neutered/spayed",
    "да": "Yes",
    "нет": "No",
    "Вес, кг": "Weight, kg",
    "Как получен вес": "Weight information source",
    "взвешен": "Weighed",
    "оценён": "Estimated",
    "Оценка мышечной массы": "Muscle mass assessment",
    "норма": "Normal",
    "лёгкая потеря": "Mild loss",
    "умеренная потеря": "Moderate loss",
    "выраженная потеря": "Severe loss",
    "невозможно оценить": "Unable to assess",
    "Обхват шеи, см": "Neck circumference, cm",
    "Длина шерсти": "Coat length",
    "короткая": "Short",
    "средняя": "Medium",
    "длинная": "Long",
    "Подшёрсток": "Undercoat",
    "отсутствует": "None",
    "умеренный": "Moderate",
    "плотный": "Dense",
    "Выстриженные/выбритые участки": "Clipped/shaved areas",
    "Где и почему (выстрижено)": "Where and why the coat was clipped",
    "Диагнозы поставлены ветеринаром": "Veterinary diagnoses",
    "есть": "Present",
    "Диагнозы (описание)": "Diagnoses (description)",
    "Категория подтверждённого заболевания": "Confirmed disease category",
    "Категория — уточнение (другое)": "Disease category — other details",
    "Хроническая хромота/проблемы с суставами": "Chronic lameness/joint problems",
    "Регулярные препараты и дозировка": "Regular medications and doses",
    "Анамнез/важные комментарии": "History/important comments",
    "Где живёт": "Housing",
    "квартира/дом": "Apartment/house",
    "вольер": "Enclosure",
    "помещение приюта": "Shelter room",
    "свободный выгул": "Free range",
    "другое": "Other",
    "Где живёт — уточнение (другое)": "Housing — other details",
    "Прогулки (частота и продолжительность)": "Walks (frequency and duration)",
    "Проживание с другими животными": "Living with other animals",
    "одна": "Alone",
    "с другими собаками": "With other dogs",
    "с другими животными": "With other animals",
    "Разрешение на съёмку": "Recording permission",
    "не требуется": "Not required",
    "Примечания": "Notes",
    "ФИО специалиста, проводящего запись": "Recording specialist's full name",
    "Дата и время сохранения заполняются автоматически.": "The save date and time are recorded automatically.",
    "Анкета сессии": "Session questionnaire",
    "Собака связывается с выбранной карточкой. Фактические время и длительность записываются автоматически.": "The dog is linked to the selected profile. Actual timing and duration are recorded automatically.",
    "Вид сессии": "Session type",
    "Активность": "Activity",
    "Сердцебиение": "Heartbeat",
    "Номер сессии *": "Session number *",
    "Анкета по сердцебиению заполняется после записи. Контрольные файлы можно добавить позже.": "Complete the heart questionnaire after recording. Reference files can be added later.",
    "Записывать видео (необязательно)": "Record video (optional)",
    "Дата сессии (ГГГГ-ММ-ДД)": "Session date (YYYY-MM-DD)",
    "Время начала записи (ЧЧ:ММ, для импорта)": "Recording start time (HH:MM, for import)",
    "Время окончания (ЧЧ:ММ, для импорта)": "End time (HH:MM, for import)",
    "Фактическая продолжительность, мин (для импорта)": "Actual duration, min (for import)",
    "Кто проводил запись": "Recording operator",
    "Что планировалось записывать *": "Planned recording activities *",
    "Аллюр/движение": "Gait/movement",
    "Покой": "Rest",
    "Другое": "Other",
    "Формат записи — уточнение (другое)": "Recording format — other details",
    "Где проходила сессия": "Session location",
    "В помещении": "Indoors",
    "На улице": "Outdoors",
    "Поверхность": "Surface",
    "Асфальт": "Asphalt",
    "Бетон": "Concrete",
    "Плитка": "Tile",
    "Грунт": "Soil",
    "Трава": "Grass",
    "Гравий": "Gravel",
    "Дерево": "Wood",
    "Ламинат": "Laminate",
    "Ковёр": "Carpet",
    "Снег": "Snow",
    "Поверхность — уточнение (другое)": "Surface — other details",
    "Температура воздуха, °C": "Air temperature, °C",
    "Положение блока": "Sensor unit position",
    "Снизу на горле": "Under the throat",
    "Сбоку слева": "Left side",
    "Сбоку справа": "Right side",
    "Сверху на шее": "Top of the neck",
    "Положение блока — уточнение (другое)": "Sensor unit position — other details",
    "Насколько затянут ошейник": "Collar tightness",
    "Свободно": "Loose",
    "Плотно": "Snug",
    "Туго": "Tight",
    "Состояние животного перед записью": "Animal's state before recording",
    "Спало": "Asleep",
    "Спокойно лежало не менее 10 минут": "Lying calmly for at least 10 minutes",
    "Спокойно бодрствовало": "Calm and awake",
    "Гуляло": "Walking",
    "Бегало/играло": "Running/playing",
    "Состояние перед записью — уточнение (другое)": "State before recording — other details",
    "Когда последний раз получал препарат (ЧСС/дыхание/активность)": "Last medication time (heart rate/breathing/activity)",
    "Записывать видео": "Record video",
    "Анкета по активности и сердцебиению": "Activity and heart questionnaire",
    "Опишите состояние собаки и условия записи. Анкета не ставит диагноз и не изменяет карточку собаки. Заполните все обязательные вопросы; если ответ неизвестен, выберите «Неизвестно».": "Describe the dog's state and recording conditions. This questionnaire does not diagnose or change the dog profile. Answer every required question; choose Unknown when you do not know.",
    "1. Сведения о сердце и препаратах": "1. Heart and medication information",
    "1.1. Диагностировал ли ветеринар заболевание сердца или нарушение ритма? *": "1.1. Has a veterinarian diagnosed heart disease or a rhythm disorder? *",
    "Какой диагноз? (необязательно)": "Diagnosis (optional)",
    "1.2. Принимала ли собака препараты, которые могут повлиять на частоту сердечных сокращений (ЧСС)? *": "1.2. Has the dog taken medication that may affect heart rate? *",
    "Название препарата и время последнего приёма (необязательно)": "Medication name and last dose time (optional)",
    "Если оператор не знает, не нужно оценивать препарат самостоятельно — выберите «Неизвестно».": "If the operator does not know, do not assess the medication yourself — choose Unknown.",
    "2. Условия записи": "2. Recording conditions",
    "2.1. Что собака делала непосредственно перед началом записи? *": "2.1. What was the dog doing immediately before recording? *",
    "2.2. Что собака фактически делала во время записи? *": "2.2. What was the dog actually doing during recording? *",
    "2.3. Были ли во время записи факторы, способные изменить ЧСС? *": "2.3. Were there factors during recording that could affect heart rate? *",
    "«Нет» и «Неизвестно» нельзя сочетать с другими вариантами.": "No and Unknown cannot be combined with other options.",
    "3. Контрольное измерение": "3. Reference measurement",
    "3.1. Есть ли независимое измерение сердцебиения за тот же период? *": "3.1. Is there an independent heart measurement for the same period? *",
    "Файл или идентификатор контрольной записи и её временная привязка *": "Reference recording file or ID and its time alignment *",
    "Измеренная ЧСС, уд/мин *": "Measured heart rate, bpm *",
    "Время измерения (UTC, ГГГГ-ММ-ДДTЧЧ:ММ:ССZ) *": "Measurement time (UTC, YYYY-MM-DDTHH:MM:SSZ) *",
    "Файл ЭКГ или интервалы с временными метками нужны для проверки отдельных ударов. Одиночное значение ЧСС подходит только для сравнения среднего темпа. По ответам анкеты нельзя делать заключение об аритмии.": "An ECG file or timestamped intervals are needed to check individual beats. A single heart-rate value only supports comparison of the average rate. Questionnaire answers cannot establish an arrhythmia diagnosis.",
    "Не указано": "Not specified",
    "Добавить контрольную запись": "Add reference recording",
    "Выберите тип данных": "Choose a data type",
    "Тип данных *": "Data type *",
    "ЭКГ": "ECG",
    "ЧСС": "Heart rate",
    "Интервалы между ударами (Polar и др.)": "Beat-to-beat intervals (Polar, etc.)",
    "Устройство / источник *": "Device / source *",
    "Начало контрольной записи UTC * (ГГГГ-ММ-ДДTЧЧ:ММ:ССZ)": "Reference recording start UTC * (YYYY-MM-DDTHH:MM:SSZ)",
    "Окончание контрольной записи UTC *": "Reference recording end UTC *",
    "Поправка к UTC таргета, мс (добавляется к его меткам, если известна)": "Target UTC offset, ms (added to its timestamps, if known)",
    "Временная привязка / примечания": "Time alignment / notes",
    "Оригинальный файл сохраняется без преобразований. ЧСС без интервалов подходит только для сравнения среднего темпа.": "The original file is preserved without conversion. Heart rate without intervals only supports comparison of the average rate.",
    "Укажите ID животного (до 100 символов)": "Enter an animal ID (up to 100 characters)",
    "Укажите кличку (до 100 символов)": "Enter a name (up to 100 characters)",
    "Укажите 0–40 лет": "Enter 0–40 years",
    "Укажите 0–11 месяцев": "Enter 0–11 months",
    "Вес должен быть >0 и ≤150 кг": "Weight must be >0 and ≤150 kg",
    "Обхват должен быть >0 и ≤150 см; оставьте пустым, если не измерен": "Circumference must be >0 and ≤150 cm; leave blank if not measured",
    "Укажите номер сессии (до 100 символов)": "Enter a session number (up to 100 characters)",
    "Выберите вид сессии": "Choose a session type",
    "Выберите формат записи": "Choose a recording format",
    "Проверьте поверхности": "Check the selected surfaces",
    "Температура: −60…70 °C": "Temperature: −60…70 °C",
    "Продолжительность должна быть ≥0": "Duration must be ≥0",
    "Дата: ГГГГ-ММ-ДД": "Date: YYYY-MM-DD",
    "Время: ЧЧ:ММ": "Time: HH:MM",
    "Нет": "No",
    "Да": "Yes",
    "Неизвестно": "Unknown",
    "Спала": "Asleep",
    "Спокойно лежала": "Lying calmly",
    "Спокойно бодрствовала": "Calm and awake",
    "Гуляла, бегала или играла": "Walking, running or playing",
    "Спала или находилась в покое": "Asleep or resting",
    "Ходила": "Walking",
    "Бегала или играла": "Running or playing",
    "Активность менялась": "Activity varied",
    "Стресс или испуг": "Stress or fright",
    "Боль": "Pain",
    "Перегрев": "Overheating",
    "ЭКГ с временными метками": "Timestamped ECG",
    "Polar с интервалами между ударами и временными метками": "Polar beat-to-beat intervals with timestamps",
    "Только число ЧСС, измеренное вручную или прибором": "Heart-rate value only, measured manually or with a device",
    "Выберите ответ": "Choose an answer",
    "Нет и Неизвестно выбираются отдельно": "No and Unknown must be selected alone",
    "Укажите запись и временную привязку": "Provide the recording and time alignment",
    "Введите положительную ЧСС": "Enter a positive heart rate",
    "Введите время UTC, например 2026-10-05T12:00:00Z": "Enter a UTC time, for example 2026-10-05T12:00:00Z",
    "Максимум 2000 символов": "Maximum 2000 characters",
    "Укажите устройство/источник (до 200 символов)": "Enter a device/source (up to 200 characters)",
    "Введите время начала UTC": "Enter the start time in UTC",
    "Введите окончание не раньше начала": "Enter an end time at or after the start",
    "Введите число или оставьте пустым": "Enter a number or leave blank",
    "Выберите тип": "Choose a type",
    "Введите время UTC": "Enter a UTC time",
    "Выберите факторы; Нет и Неизвестно выбираются отдельно": "Choose factors; No and Unknown must be selected alone",
    "«Нет» и «Неизвестно» нельзя совмещать с другими ответами": "No and Unknown cannot be combined with other answers",
    "Неподдерживаемая версия анкеты": "Unsupported questionnaire schema",
    "Обязательное поле": "Required",
    "Для неизвестного возраста нельзя указывать оценку": "Unknown age cannot contain an estimate",
    "Укажите годы или месяцы": "Enter years or months",
    "Поле должно быть пустым": "Must be empty",
    "Некорректный или повторяющийся признак": "Invalid or duplicate sign",
    "Значение вне допустимого диапазона": "Out of range",
    "Выберите активность": "Choose an activity",
    "Выберите поверхность": "Choose a surface",
    "Укажите корректное время измерения": "Enter a valid measurement time",
    "Собака связывается с выбранной карточкой. Технические время и длительность записываются автоматически.": "The dog is linked to the selected profile. Actual timing and duration are recorded automatically.",
    "Время измерения UTC * (ГГГГ-ММ-ДДTЧЧ:ММ:ССZ)": "Measurement time UTC * (YYYY-MM-DDTHH:MM:SSZ)",
    "Сохранение не подтверждено. Черновик остаётся открытым. Проверьте причину и повторите.": "Saving was not confirmed. The draft remains open. Check the cause and retry.",
    "Анкета не сохранена на устройстве. Черновик остаётся открытым; устраните причину и повторите сохранение.": "The questionnaire was not saved on this device. The draft remains open; resolve the cause and retry saving.",
    "Контрольный файл пуст": "The reference file is empty",
    "Идентификация": "Identification",
    "Возраст и пол": "Age and sex",
    "Тело": "Body",
    "Здоровье": "Health",
    "Содержание": "Housing",
    "Сессия": "Session",
    "Условия": "Conditions",
    "Состояние": "State",
    "Сведения о сессии": "Session details",
    "ФИО специалиста": "Specialist name",
    "Редактировать ответы по сердцебиению": "Edit heart questionnaire",
    "Отмена": "Cancel",
    "Сохранить": "Save",
    "Продолжить": "Continue",
    "Добавить": "Add",
    "Позже": "Later",
    "Анкета": "Questionnaire",
    "Анкета по сердцебиению": "Heart questionnaire",
]

func questionnaireSaveError(_ error: Error, language: AppLanguage) -> String {
    let prefix = language == .russian
        ? "Анкета не сохранена на устройстве. Черновик остаётся открытым; устраните причину и повторите сохранение."
        : "The questionnaire was not saved on this device. Your draft remains open; correct the cause and retry."
    return prefix + "\n" + questionnaireDisplayText(error.localizedDescription, language: language)
}

func questionnaireFieldTitle(_ key: String, language: AppLanguage) -> String {
    let labels: [String: String] = [
        "animalId": "Номер/ID животного *",
        "shelterOrPlace": "Приют/лагерь/место сбора",
        "breedName": "Порода",
        "resembles": "Если метис — похожая порода/тип",
        "shavedAreasDetails": "Где и почему (выстрижено)",
        "diagnosesDetails": "Диагнозы (описание)",
        "diseaseCategory": "Категория подтверждённого заболевания",
        "diseaseCategoryDetails": "Категория — уточнение (другое)",
        "chronicLameness": "Хроническая хромота/проблемы с суставами",
        "medications": "Регулярные препараты и дозировка",
        "history": "Анамнез/важные комментарии",
        "housingDetails": "Где живёт — уточнение (другое)",
        "walksDescription": "Прогулки (частота и продолжительность)",
        "specialistName": "ФИО специалиста, проводящего запись",
        "operatorName": "Кто проводил запись",
        "activityDetails": "Формат записи — уточнение (другое)",
        "surfaceDetails": "Поверхность — уточнение (другое)",
        "sensorPositionDetails": "Положение блока — уточнение (другое)",
        "preMeasurementStateDetails": "Состояние перед записью — уточнение (другое)",
        "lastMedicationAt": "Когда последний раз получал препарат (ЧСС/дыхание/активность)",
        "referenceArtifact": "Файл или идентификатор контрольной записи и её временная привязка *",
        "details": "Примечания",
        "knownHeartCondition": "1.1. Диагностировал ли ветеринар заболевание сердца или нарушение ритма? *",
        "heartRelevantMedication": "1.2. Принимала ли собака препараты, которые могут повлиять на частоту сердечных сокращений (ЧСС)? *",
        "preRecordingState": "2.1. Что собака делала непосредственно перед началом записи? *",
        "actualActivity": "2.2. Что собака фактически делала во время записи? *",
        "acuteHeartRateFactors": "2.3. Были ли во время записи факторы, способные изменить ЧСС? *",
        "referenceMeasurementKind": "3.1. Есть ли контрольное измерение? *",

        "numberOrName": "Кличка *",
        "ageYears": "Возраст, лет",
        "ageMonths": "Возраст, месяцев",
        "weightKg": "Вес, кг",
        "bodyConditionScore": "BCS (1-9)",
        "neckCircumferenceCm": "Обхват шеи, см",
        "sessionLabel": "Номер сессии *",
        "plannedActivities": "Что планировалось записывать *",
        "sessionKind": "Вид сессии",
        "surfaces": "Условия",
        "airTemperatureC": "Температура воздуха, °C",
        "durationMinutes": "Фактическая продолжительность, мин (для импорта)",
        "sessionDate": "Дата сессии (ГГГГ-ММ-ДД)",
        "startTime": "Время начала записи (ЧЧ:ММ, для импорта)",
        "endTime": "Время окончания (ЧЧ:ММ, для импорта)",
        "heartQuestionnaire": "Анкета по сердцебиению",
        "source": "Устройство / источник *",
        "startedAtUtc": "Начало контрольной записи UTC * (ГГГГ-ММ-ДДTЧЧ:ММ:ССZ)",
        "endedAtUtc": "Окончание контрольной записи UTC *",
        "offsetFromRecordingMs": "Поправка к UTC таргета, мс (добавляется к его меткам, если известна)",
        "notes": "Примечания",
        "type": "Тип данных *",
        "referenceBpm": "Измеренная ЧСС, уд/мин *",
        "referenceMeasuredAtUtc": "Время измерения UTC * (ГГГГ-ММ-ДДTЧЧ:ММ:ССZ)",
    ]
    return questionnaireDisplayText(labels[key] ?? "Анкета", language: language)
}

// A failed response can follow a committed server save. A retry reconciles answers
// before treating a revision conflict as a new edit; capture files never change here.
struct QuestionnaireRevisionConflict: LocalizedError {
    let questionnaire: SessionQuestionnaire
    let revision: Int
    var errorDescription: String? { "HTTP 409: questionnaire_revision_conflict — анкета изменена на сервере / questionnaire changed on the server" }
}

func questionnaireAnswersMatch(_ lhs: SessionQuestionnaire, _ rhs: SessionQuestionnaire) -> Bool {
    var left = lhs; var right = rhs
    left.savedAtLocal = nil; right.savedAtLocal = nil
    return left == right
}

@MainActor
final class QuestionnaireSaveState: ObservableObject {
    @Published var isSaving = false
    @Published var error: String?
    @Published var conflict: QuestionnaireRevisionConflict?
    @Published var expectedRevision: Int?

    func save(language: AppLanguage, operation: () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true; error = nil; conflict = nil
        defer { isSaving = false }
        do { try await operation(); return true }
        catch let conflict as QuestionnaireRevisionConflict { self.conflict = conflict; return false }
        catch {
            self.error = (language == .russian
                ? "Сохранение не подтверждено. Черновик остаётся открытым. Проверьте причину и повторите."
                : "Save has not been confirmed. Your draft remains open. Review the cause and retry.") + "\n" + error.localizedDescription
            return false
        }
    }
}

private struct QuestionnaireSaveStatus: View {
    @ObservedObject var state: QuestionnaireSaveState
    let language: AppLanguage
    var useServer: ((SessionQuestionnaire) -> Void)? = nil
    var restoreDraft: (() -> Void)? = nil
    private var russian: Bool { language == .russian }
    @ViewBuilder var body: some View {
        if state.isSaving {
            ProgressView(russian ? "Сохраняем и проверяем результат…" : "Saving and checking the result…")
        }
        if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("questionnaire.saveError") }
        if let conflict = state.conflict {
            Text(russian ? "HTTP 409: на сервере уже версия \(conflict.revision). Ваш черновик сохранён в этом окне. Сравните ответы и выберите версию; исходные файлы записи не изменяются." : "HTTP 409: the server has revision \(conflict.revision). Your draft is retained in this window. Compare answers and choose a version; original capture files are preserved.")
                .foregroundStyle(.red)
            DisclosureGroup(russian ? "Ответы на сервере" : "Server answers") {
                Text(String(decoding: (try? WoonaStore.sessionQuestionnaireData(conflict.questionnaire)) ?? Data(), as: UTF8.self)).font(.caption).textSelection(.enabled)
            }
            Button(russian ? "Оставить мои правки для версии \(conflict.revision)" : "Keep my edits for revision \(conflict.revision)") {
                state.expectedRevision = conflict.revision; state.conflict = nil
                state.error = russian ? "Ваши правки оставлены. Нажмите Сохранить, чтобы заменить проверенные ответы сервера." : "Your edits are retained. Press Save to replace the reviewed server answers."
            }
            if let useServer {
                Button(russian ? "Загрузить ответы сервера и сохранить мой черновик" : "Load server answers and retain my draft") {
                    useServer(conflict.questionnaire); state.expectedRevision = conflict.revision; state.conflict = nil; state.error = nil
                }
            }
        }
        if let restoreDraft { Button(russian ? "Вернуть мои правки" : "Restore my edits", action: restoreDraft) }
    }
}

private struct LegacyDogQuestionnaireEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DogQuestionnaire
    @State private var errors: [String: String] = [:]
    @State private var saveError: String?
    let language: AppLanguage
    let onSave: (DogQuestionnaire) throws -> Void

    init(initial: DogQuestionnaire?, language: AppLanguage, onSave: @escaping (DogQuestionnaire) throws -> Void) {
        _draft = State(initialValue: initial ?? DogQuestionnaire())
        self.language = language
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if let saveError { Text(saveError).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("dog.editor.saveError") }
                    Section {
                        ProgressView(value: progress)
                        Text(language == .russian ? "Заполнено \(Int(progress * 100))%" : "Completed \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(language == .russian ? "Идентификация" : "Identification") {
                        field("numberOrName", language == .russian ? "Номер или имя" : "Number or name", text: $draft.numberOrName)
                        field("shelterOrPlace", language == .russian ? "Приют или место" : "Shelter or place", text: $draft.shelterOrPlace)
                        choice("breedStatus", language == .russian ? "Порода" : "Breed status", selection: $draft.breedStatus, values: ["purebred", "mixed", "unknown"])
                        if ["purebred", "mixed"].contains(draft.breedStatus) {
                            optionalField("breedName", language == .russian ? "Название породы" : "Breed name", value: optionalText(\.breedName))
                        }
                        if draft.breedStatus == "mixed" {
                            optionalField("resembles", language == .russian ? "На кого похожа" : "Resembles", value: optionalText(\.resembles))
                        }
                        choice("size", language == .russian ? "Размер" : "Size", selection: $draft.size, values: ["small", "medium", "large", "giant", "unknown"])
                    }

                    Section(language == .russian ? "Возраст и пол" : "Age and sex") {
                        choice("ageStatus", language == .russian ? "Возраст" : "Age status", selection: $draft.ageStatus, values: ["known", "estimated", "unknown"])
                        if ["known", "estimated"].contains(draft.ageStatus) {
                            optionalField("ageYears", language == .russian ? "Полных лет" : "Years", value: optionalInt(\.ageYears), keyboard: .numberPad)
                            optionalField("ageMonths", language == .russian ? "Месяцев" : "Months", value: optionalInt(\.ageMonths), keyboard: .numberPad)
                            choice("ageSource", language == .russian ? "Источник возраста" : "Age source", selection: $draft.ageSource, values: ["documents", "shelter_report", "dental_estimate", "operator_estimate"])
                        }
                        choice("sex", language == .russian ? "Пол" : "Sex", selection: $draft.sex, values: ["male", "female", "unknown"])
                        choice("sterilizationStatus", language == .russian ? "Стерилизация" : "Sterilization", selection: $draft.sterilizationStatus, values: ["yes", "no", "unknown"])
                    }

                    Section(language == .russian ? "Физические параметры" : "Physical measurements") {
                        choice("weightStatus", language == .russian ? "Вес" : "Weight status", selection: $draft.weightStatus, values: ["measured", "estimated", "unknown"])
                        if ["measured", "estimated"].contains(draft.weightStatus) {
                            optionalField("weightKg", language == .russian ? "Вес, кг" : "Weight, kg", value: optionalDouble(\.weightKg), keyboard: .decimalPad)
                        }
                        choice("bodyConditionStatus", language == .russian ? "Оценка кондиции" : "Body condition", selection: $draft.bodyConditionStatus, values: ["assessed", "unable"])
                        if draft.bodyConditionStatus == "assessed" {
                            optionalField("bodyConditionScore", language == .russian ? "Баллы 1–9" : "Score 1–9", value: optionalInt(\.bodyConditionScore), keyboard: .numberPad)
                        }
                        choice("muscleMass", language == .russian ? "Мышечная масса" : "Muscle mass", selection: $draft.muscleMass, values: ["normal", "mild_loss", "moderate_loss", "severe_loss", "unable"])
                        choice("neckCircumferenceStatus", language == .russian ? "Обхват шеи" : "Neck circumference", selection: $draft.neckCircumferenceStatus, values: ["measured", "not_measured"])
                        if draft.neckCircumferenceStatus == "measured" {
                            optionalField("neckCircumferenceCm", language == .russian ? "Обхват, см" : "Circumference, cm", value: optionalDouble(\.neckCircumferenceCm), keyboard: .decimalPad)
                        }
                    }

                    Section(language == .russian ? "Шерсть и признаки" : "Coat and observed signs") {
                        choice("coatLength", language == .russian ? "Длина шерсти" : "Coat length", selection: $draft.coatLength, values: ["short", "medium", "long", "unknown"])
                        choice("undercoat", language == .russian ? "Подшёрсток" : "Undercoat", selection: $draft.undercoat, values: ["none", "moderate", "dense", "unknown"])
                        choice("shavedAreasStatus", language == .russian ? "Выбритые участки" : "Shaved areas", selection: $draft.shavedAreasStatus, values: ["none", "present", "unknown"])
                        if draft.shavedAreasStatus == "present" {
                            optionalField("shavedAreasDetails", language == .russian ? "Описание" : "Details", value: optionalText(\.shavedAreasDetails))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(language == .russian ? "Наблюдаемые признаки" : "Observed signs")
                            ForEach(DogQuestionnaire.observedSignValues.sorted(), id: \.self) { value in
                                Toggle(optionTitle(value), isOn: signBinding(value))
                            }
                            errorText("observedSigns")
                        }
                        .id("observedSigns")
                    }

                    Section(language == .russian ? "Здоровье и содержание" : "Health and housing") {
                        choice("diagnosesStatus", language == .russian ? "Диагнозы" : "Diagnoses", selection: $draft.diagnosesStatus, values: ["yes", "no", "unknown"])
                        if draft.diagnosesStatus == "yes" {
                            optionalField("diagnosesDetails", language == .russian ? "Диагнозы" : "Diagnosis details", value: optionalText(\.diagnosesDetails))
                        }
                        choice("housing", language == .russian ? "Содержание" : "Housing", selection: $draft.housing, values: ["enclosure", "room", "home", "free_range", "other", "unknown"])
                        if draft.housing == "other" {
                            optionalField("housingDetails", language == .russian ? "Описание" : "Housing details", value: optionalText(\.housingDetails))
                        }
                        choice("walksStatus", language == .russian ? "Прогулки" : "Walks", selection: $draft.walksStatus, values: ["known", "none", "unknown"])
                        if draft.walksStatus == "known" {
                            optionalField("walksDescription", language == .russian ? "Режим прогулок" : "Walk description", value: optionalText(\.walksDescription))
                        }
                        choice("cohabitants", language == .russian ? "Совместное проживание" : "Cohabitants", selection: $draft.cohabitants, values: ["alone", "other_animals", "people_only", "unknown"])
                        choice("shelterPermission", language == .russian ? "Разрешение приюта" : "Shelter permission", selection: $draft.shelterPermission, values: ["yes", "no", "not_required", "unknown"])
                        choice("notesStatus", language == .russian ? "Заметки" : "Notes", selection: $draft.notesStatus, values: ["none", "provided"])
                        if draft.notesStatus == "provided" {
                            optionalField("notes", language == .russian ? "Заметки" : "Notes", value: optionalText(\.notes))
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(language == .russian ? "Отмена" : "Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(language == .russian ? "Сохранить" : "Save") {
                            var candidate = draft
                            candidate.normalizeConditionals()
                            let validation = candidate.validate()
                            errors = validation.errors
                            guard validation.isValid else {
                                if let first = Self.fieldOrder.first(where: { errors[$0] != nil }) {
                                    withAnimation { proxy.scrollTo(first, anchor: .center) }
                                }
                                return
                            }
                            draft = candidate
                            saveError = nil
                            do { try onSave(candidate); dismiss() }
                            catch { saveError = questionnaireSaveError(error, language: language) }
                        }
                    }
                }
                .navigationTitle(language == .russian ? "Анкета собаки" : "Dog questionnaire")
            }
        }
    }

    private var progress: Double {
        max(0, 1 - Double(draft.validate().errors.count) / Double(Self.fieldOrder.count))
    }

    private func field(_ id: String, _ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) { TextField(title, text: text); errorText(id) }.id(id)
    }

    private func optionalField(_ id: String, _ title: String, value: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading) { TextField(title, text: value).keyboardType(keyboard); errorText(id) }.id(id)
    }

    private func choice(_ id: String, _ title: String, selection: Binding<String>, values: [String]) -> some View {
        VStack(alignment: .leading) {
            Picker(title, selection: selection) { ForEach(values, id: \.self) { Text(optionTitle($0)).tag($0) } }
            errorText(id)
        }.id(id)
    }

    @ViewBuilder private func errorText(_ id: String) -> some View {
        if let error = errors[id] { Text(questionnaireValidationError(error, language: language)).font(.caption).foregroundStyle(.red) }
    }

    private func optionalText(_ path: WritableKeyPath<DogQuestionnaire, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: path] ?? "" }, set: { draft[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private func optionalInt(_ path: WritableKeyPath<DogQuestionnaire, Int?>) -> Binding<String> {
        Binding(get: { draft[keyPath: path].map(String.init) ?? "" }, set: { draft[keyPath: path] = Int($0) })
    }
    private func optionalDouble(_ path: WritableKeyPath<DogQuestionnaire, Double?>) -> Binding<String> {
        Binding(get: { draft[keyPath: path].map { String($0) } ?? "" }, set: { draft[keyPath: path] = Double($0.replacingOccurrences(of: ",", with: ".")) })
    }
    private func signBinding(_ value: String) -> Binding<Bool> {
        Binding(
            get: { draft.observedSigns.contains(value) },
            set: { selected in
                if selected {
                    draft.observedSigns = ["none", "unknown"].contains(value) ? [value] : draft.observedSigns.filter { !["none", "unknown"].contains($0) } + [value]
                } else {
                    draft.observedSigns.removeAll { $0 == value }
                }
            }
        )
    }
    private func optionTitle(_ value: String) -> String { questionnaireOptionTitle(value, language: language) }

    private static let fieldOrder = [
        "numberOrName", "shelterOrPlace", "breedStatus", "breedName", "resembles", "size",
        "ageStatus", "ageYears", "ageMonths", "ageSource", "sex", "sterilizationStatus",
        "weightStatus", "weightKg", "bodyConditionStatus", "bodyConditionScore", "muscleMass",
        "neckCircumferenceStatus", "neckCircumferenceCm", "coatLength", "undercoat",
        "shavedAreasStatus", "shavedAreasDetails", "observedSigns", "diagnosesStatus",
        "diagnosesDetails", "housing", "housingDetails", "walksStatus", "walksDescription",
        "cohabitants", "shelterPermission", "notesStatus", "notes",
    ]
}

struct LegacySessionQuestionnaireEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SessionQuestionnaire()
    @State private var errors: [String: String] = [:]
    @StateObject private var saveState = QuestionnaireSaveState()
    @State private var retainedDrafts: [SessionQuestionnaire] = []
    let language: AppLanguage
    let source: String
    let onSave: (SessionQuestionnaire, Int?) async throws -> Void
    let initial: SessionQuestionnaire?

    init(language: AppLanguage, source: String, initial: SessionQuestionnaire? = nil, onSave: @escaping (SessionQuestionnaire, Int?) async throws -> Void) {
        self.language = language
        self.source = source
        self.initial = initial
        self.onSave = onSave
        _draft = State(initialValue: initial ?? SessionQuestionnaire())
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    QuestionnaireSaveStatus(state: saveState, language: language,
                        useServer: { latest in
                            retainedDrafts.append(draft)
                            draft = latest
                        }, restoreDraft: retainedDrafts.isEmpty ? nil : {
                            if let retainedDraft = retainedDrafts.popLast() { draft = retainedDraft }
                        })

                    Section {
                        ProgressView(value: progress)
                        Toggle(language == .russian ? "Записывать видео" : "Record video", isOn: $draft.videoRequested)
                            .disabled(source == "replay" || initial != nil)
                    }
                    Section(language == .russian ? "Сессия" : "Session") {
                        field("sessionLabel", language == .russian ? "Название" : "Session label", text: $draft.sessionLabel)
                        field("operatorName", language == .russian ? "Оператор" : "Operator", text: $draft.operatorName)
                        choice("activityGroup", language == .russian ? "Группа активности" : "Activity group", selection: $draft.activityGroup, values: SessionQuestionnaire.activityTypes.keys.sorted())
                        choice("activityType", language == .russian ? "Активность" : "Activity", selection: $draft.activityType, values: SessionQuestionnaire.activityTypes[draft.activityGroup]?.sorted() ?? [])
                        if ["mixed", "other"].contains(draft.activityType) { optionalField("activityDetails", detailsTitle, value: optionalText(\.activityDetails)) }
                    }
                    Section(language == .russian ? "Условия" : "Environment") {
                        choice("location", language == .russian ? "Место" : "Location", selection: $draft.location, values: ["indoors", "outdoors"])
                        choice("surface", language == .russian ? "Поверхность" : "Surface", selection: $draft.surface, values: SessionQuestionnaire.surfaces[draft.location]?.sorted() ?? [])
                        if draft.surface == "other" { optionalField("surfaceDetails", detailsTitle, value: optionalText(\.surfaceDetails)) }
                        measurement("airTemperature", title: language == .russian ? "Температура воздуха" : "Air temperature", status: $draft.airTemperatureStatus, value: optionalDouble(\.airTemperatureC))
                        choice("sensorPosition", language == .russian ? "Положение датчика" : "Sensor position", selection: $draft.sensorPosition, values: ["dorsal_neck", "left_neck", "right_neck", "chest", "back", "other"])
                        if draft.sensorPosition == "other" { optionalField("sensorPositionDetails", detailsTitle, value: optionalText(\.sensorPositionDetails)) }
                        choice("collarTightness", language == .russian ? "Затяжка ошейника" : "Collar tightness", selection: $draft.collarTightness, values: ["loose", "snug", "tight"])
                    }
                    Section(language == .russian ? "Состояние" : "State and measurements") {
                        choice("preMeasurementState", language == .russian ? "Состояние до замера" : "Pre-measurement state", selection: $draft.preMeasurementState, values: ["rest", "walk", "run", "play", "stress", "other", "unknown"])
                        if draft.preMeasurementState == "other" { optionalField("preMeasurementStateDetails", detailsTitle, value: optionalText(\.preMeasurementStateDetails)) }
                        measurement("pulse", title: language == .russian ? "Пульс" : "Pulse", status: $draft.pulseStatus, value: optionalInt(\.pulseBpm))
                        measurement("respiration", title: language == .russian ? "Дыхание" : "Respiration", status: $draft.respirationStatus, value: optionalInt(\.respirationPerMinute))
                        measurement("bodyTemperature", title: language == .russian ? "Температура тела" : "Body temperature", status: $draft.bodyTemperatureStatus, value: optionalDouble(\.bodyTemperatureC))
                        if [draft.pulseStatus, draft.respirationStatus, draft.bodyTemperatureStatus].contains("measured") {
                            optionalField("measurementAtUtc", language == .russian ? "Время ISO-8601" : "Measurement time ISO-8601", value: optionalText(\.measurementAtUtc))
                        }
                    }
                }
                .onAppear { if initial == nil && source == "replay" { draft.videoRequested = false } }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(language == .russian ? "Отмена" : "Cancel") { dismiss() }.disabled(saveState.isSaving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(language == .russian ? "Продолжить" : "Continue") {
                            var candidate = draft
                            candidate.normalizeConditionals()
                            if [candidate.pulseStatus, candidate.respirationStatus, candidate.bodyTemperatureStatus].contains("measured"),
                               candidate.measurementAtUtc == nil {
                                candidate.measurementAtUtc = WoonaStore.iso8601(Date())
                            }
                            let validation = candidate.validate()
                            errors = validation.errors
                            guard validation.isValid else {
                                if let first = Self.fieldOrder.first(where: { errors[$0] != nil }) { withAnimation { proxy.scrollTo(first, anchor: .center) } }
                                return
                            }
                            draft = candidate
                            Task { if await saveState.save(language: language, operation: { try await onSave(candidate, saveState.expectedRevision) }) { dismiss() } }
                        }.disabled(saveState.isSaving || saveState.conflict != nil)
                    }
                }
                .disabled(saveState.isSaving)
            .interactiveDismissDisabled(saveState.isSaving)
                .navigationTitle(language == .russian ? "Анкета сессии" : "Session questionnaire")
            }
        }
    }

    private var progress: Double { max(0, 1 - Double(draft.validate().errors.count) / Double(Self.fieldOrder.count)) }
    private func field(_ id: String, _ title: String, text: Binding<String>) -> some View { VStack(alignment: .leading) { TextField(title, text: text); errorText(id) }.id(id) }
    private func optionalField(_ id: String, _ title: String, value: Binding<String>) -> some View { VStack(alignment: .leading) { TextField(title, text: value); errorText(id) }.id(id) }
    private func choice(_ id: String, _ title: String, selection: Binding<String>, values: [String]) -> some View {
        VStack(alignment: .leading) { Picker(title, selection: selection) { ForEach(values, id: \.self) { Text(optionTitle($0)).tag($0) } }; errorText(id) }.id(id)
    }
    private func measurement(_ id: String, title: String, status: Binding<String>, value: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Picker(title, selection: status) { Text(optionTitle("measured")).tag("measured"); Text(optionTitle("not_measured")).tag("not_measured") }
            if status.wrappedValue == "measured" { TextField(title, text: value).keyboardType(.decimalPad) }
            errorText(id); errorText("\(id)Status")
        }.id(id)
    }
    @ViewBuilder private func errorText(_ id: String) -> some View { if let error = errors[id] { Text(questionnaireValidationError(error, language: language)).font(.caption).foregroundStyle(.red) } }
    private func optionalText(_ path: WritableKeyPath<SessionQuestionnaire, String?>) -> Binding<String> { Binding(get: { draft[keyPath: path] ?? "" }, set: { draft[keyPath: path] = $0.isEmpty ? nil : $0 }) }
    private func optionalInt(_ path: WritableKeyPath<SessionQuestionnaire, Int?>) -> Binding<String> { Binding(get: { draft[keyPath: path].map(String.init) ?? "" }, set: { draft[keyPath: path] = Int($0) }) }
    private func optionalDouble(_ path: WritableKeyPath<SessionQuestionnaire, Double?>) -> Binding<String> { Binding(get: { draft[keyPath: path].map { String($0) } ?? "" }, set: { draft[keyPath: path] = Double($0.replacingOccurrences(of: ",", with: ".")) }) }
    private var detailsTitle: String { language == .russian ? "Описание" : "Details" }
    private func optionTitle(_ value: String) -> String { questionnaireOptionTitle(value, language: language) }
    private static let fieldOrder = ["sessionLabel", "operatorName", "activityGroup", "activityType", "activityDetails", "location", "surface", "surfaceDetails", "airTemperature", "sensorPosition", "sensorPositionDetails", "collarTightness", "preMeasurementState", "preMeasurementStateDetails", "pulse", "respiration", "bodyTemperature", "measurementAtUtc"]
}

private func questionnaireOptionTitle(_ value: String, language: AppLanguage) -> String {
    guard language == .russian else { return value.replacingOccurrences(of: "_", with: " ").capitalized }
    return russianQuestionnaireOptions[value] ?? value.replacingOccurrences(of: "_", with: " ").capitalized
}

func questionnaireValidationError(_ error: String, language: AppLanguage) -> String {
    guard language == .russian else { return questionnaireDisplayText(error, language: language) }
    if error.hasPrefix("Maximum ") {
        return error.replacingOccurrences(of: "Maximum ", with: "Максимум ").replacingOccurrences(of: " characters", with: " символов")
    }
    return [
        "Required": "Обязательное поле",
        "Must be empty": "Поле должно быть пустым",
        "Choose an activity": "Выберите активность",
        "Choose a surface": "Выберите поверхность",
        "Unsupported schema": "Неподдерживаемая версия анкеты",
        "Enter years or months": "Укажите годы или месяцы",
        "Unknown age cannot contain an estimate": "Для неизвестного возраста нельзя указывать оценку",
        "Invalid or duplicate sign": "Некорректный или повторяющийся признак",
        "None/unknown cannot be combined": "«Нет» и «Неизвестно» нельзя совмещать с другими ответами",
        "Out of range": "Значение вне допустимого диапазона",
        "Enter a valid measurement time": "Укажите корректное время измерения",
    ][error] ?? (error.hasPrefix("Use ") ? "Значение вне допустимого диапазона" : error)
}

private let russianQuestionnaireOptions: [String: String] = [
    "purebred": "Породистая", "mixed": "Метис", "unknown": "Неизвестно",
    "small": "Маленький", "medium": "Средний", "large": "Большой", "giant": "Гигантский",
    "known": "Известно", "estimated": "Оценено", "documents": "Документы",
    "shelter_report": "Данные приюта", "dental_estimate": "Оценка по зубам",
    "operator_estimate": "Оценка оператора", "male": "Самец", "female": "Самка",
    "yes": "Да", "no": "Нет", "measured": "Измерено", "not_measured": "Не измерено",
    "assessed": "Оценено", "unable": "Невозможно оценить", "normal": "Норма",
    "mild_loss": "Лёгкая потеря", "moderate_loss": "Умеренная потеря",
    "severe_loss": "Выраженная потеря", "short": "Короткая", "long": "Длинная",
    "none": "Нет", "moderate": "Умеренный", "dense": "Густой", "present": "Есть",
    "labored_breathing": "Затруднённое дыхание", "fainting": "Обмороки", "seizures": "Судороги",
    "cannot_urinate": "Не может помочиться", "limb_weakness": "Слабость конечностей",
    "jaundice": "Желтуха", "vomiting_or_no_appetite": "Рвота или нет аппетита",
    "stool_changes": "Изменения стула", "cough": "Кашель", "pain_or_lameness": "Боль или хромота",
    "thirst_changes": "Изменение жажды", "distress": "Сильное беспокойство",
    "enclosure": "Вольер", "room": "Комната", "home": "Дом", "free_range": "Свободное содержание",
    "other": "Другое", "alone": "Один", "other_animals": "С другими животными",
    "people_only": "Только с людьми", "not_required": "Не требуется", "provided": "Указаны",
    "locomotion": "Движение", "stationary": "Без движения", "daily_living": "Повседневная активность",
    "walk": "Ходьба", "trot": "Рысь", "gallop": "Галоп", "run": "Бег",
    "stairs_up": "Подъём по лестнице", "stairs_down": "Спуск по лестнице", "jump": "Прыжок",
    "stand": "Стоит", "sit": "Сидит", "lie": "Лежит", "rest": "Отдых", "sleep": "Сон",
    "play": "Игра", "eat": "Еда", "drink": "Питьё", "scratch": "Чешется", "groom": "Уход",
    "indoors": "В помещении", "outdoors": "На улице", "tile": "Плитка", "concrete": "Бетон",
    "wood": "Дерево", "laminate": "Ламинат", "carpet": "Ковёр", "bed": "Лежанка",
    "kennel_mat": "Коврик в вольере", "asphalt": "Асфальт", "grass": "Трава", "soil": "Грунт",
    "gravel": "Гравий", "snow": "Снег", "dorsal_neck": "Сверху на шее",
    "left_neck": "Слева на шее", "right_neck": "Справа на шее", "chest": "Грудь", "back": "Спина",
    "loose": "Свободно", "snug": "Плотно", "tight": "Туго", "stress": "Стресс",
]

struct DogQuestionnaireEditor: View {
    private func q(_ value: String) -> String { questionnaireDisplayText(value, language: language) }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DogQuestionnaire
    @State private var errors: [String: String] = [:]
    @State private var saveError: String?
    let language: AppLanguage
    let onSave: (DogQuestionnaire) throws -> Void

    init(initial: DogQuestionnaire?, language: AppLanguage, onSave: @escaping (DogQuestionnaire) throws -> Void) {
        var value = initial ?? DogQuestionnaire()
        value.schemaVersion = 2
        value.species = value.species ?? "собака"
        _draft = State(initialValue: value)
        self.language = language
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                    if let saveError { Text(saveError).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("dog.editor.saveError") }
                Section(q("Идентификация")) {
                    Text(q("ID и кличка обязательны. Неизвестные ответы оставьте пустыми."))
                    TextField(q("Номер/ID животного *"), text: text(\.animalId))
                        .accessibilityIdentifier("dog.editor.animalID")
                    TextField(q("Кличка *"), text: $draft.numberOrName)
                        .accessibilityIdentifier("dog.editor.name")
                    TextField(q("Вид"), text: text(\.species))
                    TextField(q("Приют/лагерь/место сбора"), text: $draft.shelterOrPlace)
                    TextField(q("Порода"), text: text(\.breedName))
                    TextField(q("Если метис — похожая порода/тип"), text: text(\.resembles))
                    sheetPicker("Размер", language: language, selection: $draft.size, values: ["мелкий", "средний", "крупный", "гигантский"])
                }
                Section(q("Возраст и пол")) {
                    TextField(q("Возраст, лет"), text: integer(\.ageYears)).keyboardType(.numberPad)
                    TextField(q("Возраст, месяцев"), text: integer(\.ageMonths)).keyboardType(.numberPad)
                    sheetPicker("Источник данных о возрасте", language: language, selection: $draft.ageSource, values: ["документы", "со слов владельца/приюта", "оценка по зубам", "неизвестно"])
                    sheetPicker("Пол", language: language, selection: $draft.sex, values: ["самец", "самка", "неизвестно"])
                    sheetPicker("Стерилизован/кастрирован", language: language, selection: $draft.sterilizationStatus, values: ["да", "нет", "неизвестно"])
                }
                Section(q("Тело")) {
                    TextField(q("Вес, кг"), text: decimal(\.weightKg)).keyboardType(.decimalPad)
                    sheetPicker("Как получен вес", language: language, selection: $draft.weightStatus, values: ["взвешен", "со слов владельца/приюта", "оценён"])
                    TextField("BCS (1-9)", text: integer(\.bodyConditionScore)).keyboardType(.numberPad)
                    sheetPicker("Оценка мышечной массы", language: language, selection: $draft.muscleMass, values: ["норма", "лёгкая потеря", "умеренная потеря", "выраженная потеря", "невозможно оценить"])
                    TextField(q("Обхват шеи, см"), text: decimal(\.neckCircumferenceCm)).keyboardType(.decimalPad)
                    sheetPicker("Длина шерсти", language: language, selection: $draft.coatLength, values: ["короткая", "средняя", "длинная"])
                    sheetPicker("Подшёрсток", language: language, selection: $draft.undercoat, values: ["отсутствует", "умеренный", "плотный"])
                    sheetPicker("Выстриженные/выбритые участки", language: language, selection: $draft.shavedAreasStatus, values: ["да", "нет"])
                    TextField(q("Где и почему (выстрижено)"), text: text(\.shavedAreasDetails))
                }
                Section(q("Здоровье")) {
                    sheetPicker("Диагнозы поставлены ветеринаром", language: language, selection: $draft.diagnosesStatus, values: ["есть", "нет", "неизвестно"])
                    TextField(q("Диагнозы (описание)"), text: text(\.diagnosesDetails), axis: .vertical)
                    TextField(q("Категория подтверждённого заболевания"), text: text(\.diseaseCategory))
                    TextField(q("Категория — уточнение (другое)"), text: text(\.diseaseCategoryDetails))
                    sheetPicker("Хроническая хромота/проблемы с суставами", language: language, selection: text(\.chronicLameness), values: ["да", "нет", "неизвестно"])
                    TextField(q("Регулярные препараты и дозировка"), text: text(\.medications), axis: .vertical)
                    TextField(q("Анамнез/важные комментарии"), text: text(\.history), axis: .vertical)
                }
                Section(q("Содержание")) {
                    sheetPicker("Где живёт", language: language, selection: $draft.housing, values: ["квартира/дом", "вольер", "помещение приюта", "свободный выгул", "другое"])
                    TextField(q("Где живёт — уточнение (другое)"), text: text(\.housingDetails))
                    TextField(q("Прогулки (частота и продолжительность)"), text: text(\.walksDescription))
                    sheetPicker("Проживание с другими животными", language: language, selection: $draft.cohabitants, values: ["одна", "с другими собаками", "с другими животными"])
                    sheetPicker("Разрешение на съёмку", language: language, selection: $draft.shelterPermission, values: ["да", "нет", "не требуется"])
                    TextField(q("Примечания"), text: text(\.notes), axis: .vertical)
                    TextField(q("ФИО специалиста, проводящего запись"), text: text(\.specialistName))
                    Text(q("Дата и время сохранения заполняются автоматически.")).font(.caption)
                }
                ForEach(errors.keys.sorted(), id: \.self) { key in Text("\(questionnaireFieldTitle(key, language: language)): \(questionnaireValidationError(errors[key]!, language: language))").foregroundStyle(.red) }
            }
            .navigationTitle(q("Анкета собаки"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(q("Отмена")) { dismiss() }.accessibilityIdentifier("dog.editor.cancel") }
                ToolbarItem(placement: .confirmationAction) { Button(q("Сохранить")) {
                    errors = draft.validate().errors
                    guard errors.isEmpty else { return }
                    draft.savedAtLocal = sheetSavedAt()
                    saveError = nil
                    do { try onSave(draft); dismiss() }
                    catch { saveError = questionnaireSaveError(error, language: language) }
                }.accessibilityIdentifier("dog.editor.save") }
            }
        }
    }
    private func text(_ key: WritableKeyPath<DogQuestionnaire, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
    private func integer(_ key: WritableKeyPath<DogQuestionnaire, Int?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key].map(String.init) ?? "" }, set: { draft[keyPath: key] = $0.isEmpty ? nil : (Int($0) ?? Int.min) })
    }
    private func decimal(_ key: WritableKeyPath<DogQuestionnaire, Double?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key].map { String($0) } ?? "" }, set: { draft[keyPath: key] = $0.isEmpty ? nil : (Double($0.replacingOccurrences(of: ",", with: ".")) ?? .nan) })
    }
}

struct SessionQuestionnaireEditor: View {
    private func q(_ value: String) -> String { questionnaireDisplayText(value, language: language) }
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SessionQuestionnaire()
    @State private var errors: [String: String] = [:]
    @StateObject private var saveState = QuestionnaireSaveState()
    @State private var retainedDrafts: [SessionQuestionnaire] = []
    @State private var isHeartEditorPresented = false
    let language: AppLanguage
    let source: String
    let onSave: (SessionQuestionnaire, Int?) async throws -> Void
    let initial: SessionQuestionnaire?

    init(language: AppLanguage, source: String, initial: SessionQuestionnaire? = nil, onSave: @escaping (SessionQuestionnaire, Int?) async throws -> Void) {
        self.language = language
        self.source = source
        self.initial = initial
        self.onSave = onSave
        _draft = State(initialValue: initial ?? SessionQuestionnaire())
    }

    var body: some View {
        NavigationStack {
            Form {
                    QuestionnaireSaveStatus(state: saveState, language: language,
                        useServer: { latest in
                            retainedDrafts.append(draft)
                            draft = latest
                        }, restoreDraft: retainedDrafts.isEmpty ? nil : {
                            if let retainedDraft = retainedDrafts.popLast() { draft = retainedDraft }
                        })

                Section(q("Вид сессии")) {
                    Picker(q("Вид сессии"), selection: Binding(get: { draft.sessionKind ?? "activity" }, set: { draft.sessionKind = $0; if $0 == "heart" { draft.videoRequested = false } })) {
                        Text(q("Активность")).tag("activity")
                        Text(q("Сердцебиение")).tag("heart")
                    }.pickerStyle(.segmented).disabled(initial != nil)
                }
                Section(q("Сессия")) {
                    Text(q("Собака связывается с выбранной карточкой. Технические время и длительность записываются автоматически."))
                    TextField(q("Номер сессии *"), text: $draft.sessionLabel)
                    if draft.sessionKind != "heart" {
                    TextField(q("Дата сессии (ГГГГ-ММ-ДД)"), text: text(\.sessionDate))
                    TextField(q("Время начала записи (ЧЧ:ММ, для импорта)"), text: text(\.startTime))
                    TextField(q("Время окончания (ЧЧ:ММ, для импорта)"), text: text(\.endTime))
                    TextField(q("Фактическая продолжительность, мин (для импорта)"), text: decimal(\.durationMinutes)).keyboardType(.decimalPad)
                    TextField(q("Кто проводил запись"), text: $draft.operatorName)
                    }
                    Toggle(q("Записывать видео"), isOn: $draft.videoRequested).disabled(source == "replay" || initial != nil)
                }
                if draft.sessionKind != "heart" {
                Section(q("Что планировалось записывать *")) {
                    ForEach(["Аллюр/движение", "Активность", "Покой", "Другое"], id: \.self) { value in
                        Toggle(q(value), isOn: multiple(\.plannedActivities, value))
                    }
                    TextField(q("Формат записи — уточнение (другое)"), text: text(\.activityDetails))
                }
                Section(q("Условия")) {
                    sheetPicker("Где проходила сессия", language: language, selection: $draft.location, values: ["В помещении", "На улице"])
                    ForEach(["Асфальт", "Бетон", "Плитка", "Грунт", "Трава", "Гравий", "Дерево", "Ламинат", "Ковёр", "Снег", "Другое"], id: \.self) { value in
                        Toggle(q(value), isOn: multiple(\.surfaces, value))
                    }
                    TextField(q("Поверхность — уточнение (другое)"), text: text(\.surfaceDetails))
                    TextField(q("Температура воздуха, °C"), text: decimal(\.airTemperatureC)).keyboardType(.decimalPad)
                    sheetPicker("Положение блока", language: language, selection: $draft.sensorPosition, values: ["Снизу на горле", "Сбоку слева", "Сбоку справа", "Сверху на шее", "Другое"])
                    TextField(q("Положение блока — уточнение (другое)"), text: text(\.sensorPositionDetails))
                    sheetPicker("Насколько затянут ошейник", language: language, selection: $draft.collarTightness, values: ["Свободно", "Плотно", "Туго"])
                }
                Section(q("Состояние")) {
                    sheetPicker("Состояние животного перед записью", language: language, selection: $draft.preMeasurementState, values: ["Спало", "Спокойно лежало не менее 10 минут", "Спокойно бодрствовало", "Гуляло", "Бегало/играло", "Другое"])
                    TextField(q("Состояние перед записью — уточнение (другое)"), text: text(\.preMeasurementStateDetails))
                    TextField(q("Когда последний раз получал препарат (ЧСС/дыхание/активность)"), text: text(\.lastMedicationAt))
                    TextField(q("Примечания"), text: text(\.notes), axis: .vertical)
                    TextField(q("ФИО специалиста, проводящего запись"), text: text(\.specialistName))
                }
                } else if initial != nil {
                    Section(q("Сведения о сессии")) {
                        TextField(q("Кто проводил запись"), text: $draft.operatorName)
                        TextField(q("Примечания"), text: text(\.notes), axis: .vertical)
                        TextField(q("ФИО специалиста"), text: text(\.specialistName))
                        Button(q("Редактировать ответы по сердцебиению")) { isHeartEditorPresented = true }
                    }
                } else { Text(q("Анкета по сердцебиению заполняется после записи. Контрольные файлы можно добавить позже.")) }
                ForEach(errors.keys.sorted(), id: \.self) { key in Text("\(questionnaireFieldTitle(key, language: language)): \(questionnaireValidationError(errors[key]!, language: language))").foregroundStyle(.red) }
            }
            .onAppear { if initial != nil { return }; draft.schemaVersion = 2; draft.plannedActivities = draft.plannedActivities ?? []; draft.surfaces = draft.surfaces ?? []; if source == "replay" { draft.videoRequested = false } }
            .sheet(isPresented: $isHeartEditorPresented) {
                HeartQuestionnaireEditor(initial: draft.heartQuestionnaire ?? HeartQuestionnaire(), language: language) { heart, _ in draft.heartQuestionnaire = heart.normalized() }
            }
            .navigationTitle(q("Анкета сессии"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(q("Отмена")) { dismiss() }.disabled(saveState.isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button(q(initial == nil ? "Продолжить" : "Сохранить")) {
                    errors = draft.validate().errors
                    if initial != nil && !draft.readyForSync { errors["heartQuestionnaire"] = "Заполните ответы по сердцебиению" }
                    guard errors.isEmpty else { return }
                    draft.savedAtLocal = sheetSavedAt()
                    let candidate = draft
                    Task { if await saveState.save(language: language, operation: { try await onSave(candidate, saveState.expectedRevision) }) { dismiss() } }
                }.disabled(saveState.isSaving || saveState.conflict != nil) }
            }
            .disabled(saveState.isSaving)
            .interactiveDismissDisabled(saveState.isSaving)
        }
    }
    private func text(_ key: WritableKeyPath<SessionQuestionnaire, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
    private func decimal(_ key: WritableKeyPath<SessionQuestionnaire, Double?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key].map { String($0) } ?? "" }, set: { draft[keyPath: key] = $0.isEmpty ? nil : (Double($0.replacingOccurrences(of: ",", with: ".")) ?? .nan) })
    }
    private func multiple(_ key: WritableKeyPath<SessionQuestionnaire, [String]?>, _ value: String) -> Binding<Bool> {
        Binding(get: { (draft[keyPath: key] ?? []).contains(value) }, set: { selected in
            var values = draft[keyPath: key] ?? []
            values.removeAll { $0 == value }
            if selected { values.append(value) }
            draft[keyPath: key] = values
        })
    }
}

private func sheetSavedAt() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: Date())
}

private func sheetPicker(_ title: String, language: AppLanguage, selection: Binding<String>, values: [String]) -> some View {
    let current = selection.wrappedValue
    let options = [""] + values + (current.isEmpty || values.contains(current) ? [] : [current])
    return Picker(questionnaireDisplayText(title, language: language), selection: selection) {
        ForEach(options, id: \.self) { Text(questionnaireDisplayText($0.isEmpty ? "Не указано" : $0, language: language)).tag($0) }
    }.accessibilityIdentifier("questionnaire.choice." + questionnaireDisplayText(title, language: .english))
}

struct HeartQuestionnaireEditor: View {
    private func q(_ value: String) -> String { questionnaireDisplayText(value, language: language) }
    @Environment(\.dismiss) private var dismiss
    @State private var draft = HeartQuestionnaire()
    @State private var bpm = ""
    @State private var measuredAt = ""
    @State private var errors: [String: String] = [:]
    @StateObject private var saveState = QuestionnaireSaveState()
    @State private var retainedDrafts: [HeartQuestionnaire] = []
    let language: AppLanguage
    let initial: HeartQuestionnaire
    let onSave: (HeartQuestionnaire, Int?) async throws -> Void

    init(initial: HeartQuestionnaire, language: AppLanguage = .russian,
         onSave: @escaping (HeartQuestionnaire, Int?) async throws -> Void) {
        self.initial = initial; self.language = language; self.onSave = onSave
        _draft = State(initialValue: initial)
        _bpm = State(initialValue: initial.referenceBpm.map { String($0.bpm) } ?? "")
        _measuredAt = State(initialValue: initial.referenceBpm?.measuredAtUtc ?? "")
    }

    var body: some View {

        NavigationStack {
            Form {
                    QuestionnaireSaveStatus(state: saveState, language: language,
                        useServer: { latest in
                            retainedDrafts.append(draft)
                            draft = latest.heartQuestionnaire ?? HeartQuestionnaire(); bpm = draft.referenceBpm.map { String($0.bpm) } ?? ""; measuredAt = draft.referenceBpm?.measuredAtUtc ?? ""
                        }, restoreDraft: retainedDrafts.isEmpty ? nil : {
                            if let retainedDraft = retainedDrafts.popLast() { draft = retainedDraft; bpm = draft.referenceBpm.map { String($0.bpm) } ?? ""; measuredAt = draft.referenceBpm?.measuredAtUtc ?? "" }
                        })

                Text(q("Опишите состояние собаки и условия записи. Анкета не ставит диагноз и не изменяет карточку собаки. Заполните все обязательные вопросы; если ответ неизвестен, выберите «Неизвестно»."))
                Section(q("1. Сведения о сердце и препаратах")) {
                    choice("1.1. Диагностировал ли ветеринар заболевание сердца или нарушение ритма? *", "knownHeartCondition", $draft.knownHeartCondition)
                    if draft.knownHeartCondition?.key == "yes" { TextField(q("Какой диагноз? (необязательно)"), text: optional(\.knownHeartConditionDetails)) }
                    choice("1.2. Принимала ли собака препараты, которые могут повлиять на частоту сердечных сокращений (ЧСС)? *", "heartRelevantMedication", $draft.heartRelevantMedication)
                    if draft.heartRelevantMedication?.key == "yes" { TextField(q("Название препарата и время последнего приёма (необязательно)"), text: optional(\.heartRelevantMedicationDetails)) }
                    Text(q("Если оператор не знает, не нужно оценивать препарат самостоятельно — выберите «Неизвестно»."))
                }
                Section(q("2. Условия записи")) {
                    choice("2.1. Что собака делала непосредственно перед началом записи? *", "preRecordingState", $draft.preRecordingState)
                    choice("2.2. Что собака фактически делала во время записи? *", "actualActivity", $draft.actualActivity)
                    Text(q("2.3. Были ли во время записи факторы, способные изменить ЧСС? *"))
                    ForEach(HeartQuestionnaire.options["acuteHeartRateFactors"]!, id: \.key) { answer in
                        Toggle(q(answer.text), isOn: Binding(get: { draft.acuteHeartRateFactors.contains(answer) }, set: { selected in
                            draft.acuteHeartRateFactors.removeAll { $0 == answer || (selected && (["none", "unknown"].contains(answer.key) || ["none", "unknown"].contains($0.key))) }
                            if selected { draft.acuteHeartRateFactors.append(answer) }
                        }))
                    }
                    Text(q("«Нет» и «Неизвестно» нельзя сочетать с другими вариантами."))
                }
                Section(q("3. Контрольное измерение")) {
                    choice("3.1. Есть ли независимое измерение сердцебиения за тот же период? *", "referenceMethod", $draft.referenceMethod)
                    if ["ecg", "polar_rr"].contains(draft.referenceMethod?.key ?? "") {
                        TextField(q("Файл или идентификатор контрольной записи и её временная привязка *"), text: optional(\.referenceArtifact), axis: .vertical)
                    }
                    if draft.referenceMethod?.key == "bpm_only" {
                        TextField(q("Измеренная ЧСС, уд/мин *"), text: $bpm).keyboardType(.decimalPad)
                        TextField(q("Время измерения UTC * (ГГГГ-ММ-ДДTЧЧ:ММ:ССZ)"), text: $measuredAt)
                    }
                    Text(q("Файл ЭКГ или интервалы с временными метками нужны для проверки отдельных ударов. Одиночное значение ЧСС подходит только для сравнения среднего темпа. По ответам анкеты нельзя делать заключение об аритмии."))
                }
                ForEach(errors.keys.sorted(), id: \.self) { key in Text(questionnaireValidationError(errors[key]!, language: language)).foregroundStyle(.red) }
            }
            .navigationTitle(q("Анкета по активности и сердцебиению"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(q("Позже")) { dismiss() }.disabled(saveState.isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button(q("Сохранить")) {
                    if draft.referenceMethod?.key == "bpm_only" { draft.referenceBpm = HeartBpm(bpm: Double(bpm.replacingOccurrences(of: ",", with: ".")) ?? .nan, measuredAtUtc: measuredAt) }
                    errors = draft.validate().errors
                    if errors.isEmpty {
                        let candidate = draft.normalized()
                        Task { if await saveState.save(language: language, operation: { try await onSave(candidate, saveState.expectedRevision) }) { dismiss() } }
                    }
                }.disabled(saveState.isSaving || saveState.conflict != nil) }
            }
            .disabled(saveState.isSaving)
            .interactiveDismissDisabled(saveState.isSaving)
        }
    }
    private func choice(_ title: String, _ key: String, _ binding: Binding<HeartAnswer?>) -> some View {
        Picker(q(title), selection: binding) {
            Text(q("Выберите ответ")).tag(Optional<HeartAnswer>.none)
            ForEach(HeartQuestionnaire.options[key]!, id: \.key) { Text(q($0.text)).tag(Optional($0)) }
        }
    }
    private func optional(_ key: WritableKeyPath<HeartQuestionnaire, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
}

struct ReferenceAttachmentEditor: View {
    private func q(_ value: String) -> String { questionnaireDisplayText(value, language: language) }
    @Environment(\.dismiss) private var dismiss
    @State private var type = ""
    @State private var metadata = ReferenceMetadata()
    @State private var offset = ""
    @State private var errors: [String: String] = [:]
    @StateObject private var saveState = QuestionnaireSaveState()
    let url: URL
    let language: AppLanguage
    let onSave: (String, ReferenceMetadata) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                QuestionnaireSaveStatus(state: saveState, language: language)
                Text(url.lastPathComponent)
                Picker(q("Тип данных *"), selection: $type) {
                    Text(q("Выберите тип")).tag("")
                    Text(q("ЭКГ")).tag("ecg")
                    Text(q("ЧСС")).tag("heart_rate")
                    Text(q("Интервалы между ударами (Polar и др.)")).tag("rr")
                }
                TextField(q("Устройство / источник *"), text: $metadata.source)
                TextField(q("Начало контрольной записи UTC * (ГГГГ-ММ-ДДTЧЧ:ММ:ССZ)"), text: $metadata.startedAtUtc)
                TextField(q("Окончание контрольной записи UTC *"), text: $metadata.endedAtUtc)
                TextField(q("Поправка к UTC таргета, мс (добавляется к его меткам, если известна)"), text: $offset)
                TextField(q("Временная привязка / примечания"), text: Binding(get: { metadata.notes ?? "" }, set: { metadata.notes = $0 }), axis: .vertical)
                Text(q("Оригинальный файл сохраняется без преобразований. ЧСС без интервалов подходит только для сравнения среднего темпа."))
                ForEach(errors.keys.sorted(), id: \.self) { key in Text(questionnaireValidationError(errors[key]!, language: language)).foregroundStyle(.red) }
            }
            .navigationTitle(q("Добавить контрольную запись"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(q("Отмена")) { dismiss() }.disabled(saveState.isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button(q("Добавить")) {
                    metadata.offsetFromRecordingMs = offset.isEmpty ? nil : Double(offset.replacingOccurrences(of: ",", with: ".")) ?? .nan
                    errors = metadata.validate().errors
                    if type.isEmpty { errors["type"] = "Выберите тип данных" }
                    if errors.isEmpty {
                        let candidate = metadata; let selectedType = type
                        Task { if await saveState.save(language: language, operation: { try await onSave(selectedType, candidate) }) { dismiss() } }
                    }
                }.disabled(saveState.isSaving) }
            }
            .disabled(saveState.isSaving)
            .interactiveDismissDisabled(saveState.isSaving)
        }
    }
}
