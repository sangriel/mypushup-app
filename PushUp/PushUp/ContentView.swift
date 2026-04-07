import SwiftData
import SwiftUI
internal import Combine

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var appStates: [AppState]
    @Query(sort: \WorkoutCompletion.completedAt, order: .reverse) private var completions: [WorkoutCompletion]

    @State private var weeks: [RoutineWeek] = []
    @State private var loadingError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadingError {
                    ContentUnavailableView(
                        "루틴을 불러올 수 없습니다",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadingError)
                    )
                } else if weeks.isEmpty {
                    ProgressView("루틴을 불러오는 중...")
                } else if let state = appStates.first {
                    RoutineSelectionView(
                        weeks: weeks,
                        state: state,
                        completions: completions
                    )
                } else {
                    ProgressView("로컬 데이터를 준비하는 중...")
                }
            }
            .navigationTitle("PushUp")
        }
        .task {
            loadRoutineIfNeeded()
            ensureAppState()
        }
    }

    private func loadRoutineIfNeeded() {
        guard weeks.isEmpty else { return }

        do {
            weeks = try RoutineLoader.load()
        } catch {
            loadingError = error.localizedDescription
        }
    }

    private func ensureAppState() {
        guard appStates.isEmpty else { return }

        modelContext.insert(AppState())
        try? modelContext.save()
    }
}

private struct RoutineSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    let weeks: [RoutineWeek]
    @Bindable var state: AppState
    let completions: [WorkoutCompletion]

    @State private var selectedWeek: Int = 1

    var body: some View {
        List {
            Section("주차 선택") {
                Picker("주차", selection: $selectedWeek) {
                    ForEach(weeks) { week in
                        Text("\(week.week)주차").tag(week.week)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let week = weeks.first(where: { $0.week == selectedWeek }) {
                Section("\(week.week)주차 날짜 선택") {
                    ForEach(week.days.sorted { $0.day < $1.day }) { day in
                        let session = RoutineSession(week: week.week, day: day)

                        NavigationLink {
                            WorkoutDetailView(
                                session: session,
                                weeks: weeks,
                                state: state,
                                completions: completions
                            )
                        } label: {
                            dayRow(for: session)
                        }
                    }
                }
            }

            if !completions.isEmpty {
                Section("최근 완료 기록") {
                    ForEach(completions.prefix(5)) { completion in
                        completionRow(completion)
                            .swipeActions {
                                Button("삭제", role: .destructive) {
                                    deleteCompletion(completion)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("PushUp")
        .onAppear {
            if weeks.contains(where: { $0.week == state.currentWeek }) {
                selectedWeek = state.currentWeek
            } else {
                selectedWeek = weeks.first?.week ?? 1
            }
        }
    }

    private func dayRow(for session: RoutineSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isCompleted(session) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCompleted(session) ? .green : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Day \(session.day.day)")
                    .font(.headline)
                Text("휴식 \(session.day.restSeconds)초 · 범위 \(session.day.ranges.orderedRangeKeys.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state.currentWeek == session.week && state.currentDay == session.day.day {
                Text("현재")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }
        }
    }

    private func completionRow(_ completion: WorkoutCompletion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Week \(completion.week) · Day \(completion.day)")
                    .font(.headline)
                Text("\(completion.rangeKey) · 실제 수행 \(completion.actualRepsCSV)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                deleteCompletion(completion)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func isCompleted(_ session: RoutineSession) -> Bool {
        completions.contains {
            $0.week == session.week && $0.day == session.day.day
        }
    }

    private func deleteCompletion(_ completion: WorkoutCompletion) {
        modelContext.delete(completion)
        try? modelContext.save()
    }
}

private struct WorkoutDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let session: RoutineSession
    let weeks: [RoutineWeek]
    @Bindable var state: AppState
    let completions: [WorkoutCompletion]

    @State private var completedSetIndexes: Set<Int> = []
    @State private var setInputs: [Int: String] = [:]
    @State private var remainingRestSeconds = 0
    @State private var isResting = false
    @FocusState private var focusedSetIndex: Int?

    private let restTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    header(for: session)
                    rangePicker(for: session)

                    if let sets = selectedSets(for: session) {
                        restTimerView(restSeconds: session.day.restSeconds)
                        setsView(sets: sets, restSeconds: session.day.restSeconds)
                        completeButton(for: session, sets: sets)
                    }
                }
                .padding(.vertical, 6)
            }

            if !completions.isEmpty {
                Section("최근 완료 기록") {
                    ForEach(completions.prefix(8)) { completion in
                        completionRow(completion)
                            .swipeActions {
                                Button("삭제", role: .destructive) {
                                    deleteCompletion(completion)
                                }
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("모든 데이터는 이 기기에만 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        .onReceive(restTimer) { _ in
            tickRestTimer()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(KeyboardDismissTapInstaller { dismissKeyboard() })
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()

                Button("Done") {
                    dismissKeyboard()
                }
            }
        }
        .navigationTitle("Week \(session.week) · Day \(session.day.day)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(for session: RoutineSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("선택한 루틴")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Week \(session.week), Day \(session.day.day)")
                .font(.largeTitle.bold())
            Text("세트 사이 휴식 \(session.day.restSeconds)초")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func rangePicker(for session: RoutineSession) -> some View {
        Picker("현재 최대 푸시업 범위", selection: rangeBinding(for: session)) {
            ForEach(session.day.ranges.orderedRangeKeys, id: \.self) { key in
                Text(key).tag(key)
            }
        }
        .pickerStyle(.segmented)
    }

    private func setsView(sets: RoutineSets, restSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sets.targets.enumerated()), id: \.offset) { index, target in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            toggleSet(index: index, target: target, restSeconds: restSeconds)
                        } label: {
                            Image(systemName: completedSetIndexes.contains(index) ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)

                        Text("Set \(index + 1)")
                            .font(.headline)

                        Spacer()

                        Text("목표 \(target.displayText)회")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    TextField("실제 횟수", text: setInputBinding(index: index, target: target))
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedSetIndex, equals: index)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }

            Text("마지막 세트의 + 표시는 가능한 만큼 추가 수행한다는 뜻입니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func restTimerView(restSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("세트 사이 휴식 타이머", systemImage: "timer")
                    .font(.headline)

                Spacer()

                Text(isResting ? "진행 중" : "대기")
                    .font(.caption.bold())
                    .foregroundStyle(isResting ? .green : .secondary)
            }

            Text(timerDisplayText(restSeconds: restSeconds))
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Button(isResting ? "일시정지" : "시작") {
                    toggleRestTimer(restSeconds: restSeconds)
                }
                .buttonStyle(.borderedProminent)

                Button("리셋") {
                    resetRestTimer(restSeconds: restSeconds)
                }
                .buttonStyle(.bordered)
            }

            Text("세트를 완료하면 다음 세트 전 휴식 타이머가 자동으로 시작됩니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func completionRow(_ completion: WorkoutCompletion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Week \(completion.week) · Day \(completion.day)")
                    .font(.headline)
                Text("\(completion.rangeKey) · \(completion.targetRepsCSV)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("실제 수행: \(completion.actualRepsCSV)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(completion.completedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(role: .destructive) {
                deleteCompletion(completion)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func completeButton(for session: RoutineSession, sets: RoutineSets) -> some View {
        Button {
            complete(session: session, sets: sets)
        } label: {
            Label("루틴 완료", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isCompleted(session) || !allSetsCompleted)
    }

    private func rangeBinding(for session: RoutineSession) -> Binding<String> {
        Binding(
            get: {
                selectedRangeKey(for: session)
            },
            set: { newValue in
                state.selectedRangeKey = newValue
                try? modelContext.save()
            }
        )
    }

    private func selectedRangeKey(for session: RoutineSession) -> String {
        if let selectedRangeKey = state.selectedRangeKey,
           session.day.ranges[selectedRangeKey] != nil {
            return selectedRangeKey
        }

        return session.day.ranges.orderedRangeKeys.first ?? ""
    }

    private func selectedSets(for session: RoutineSession) -> RoutineSets? {
        session.day.ranges[selectedRangeKey(for: session)]
    }

    private func complete(session: RoutineSession, sets: RoutineSets) {
        let rangeKey = selectedRangeKey(for: session)
        let targetReps = sets.targets.map(\.displayText).joined(separator: ", ")
        let actualReps = sets.targets.indices.map {
            normalizedSetInput(index: $0, target: sets.targets[$0])
        }.joined(separator: ", ")

        modelContext.insert(
            WorkoutCompletion(
                week: session.week,
                day: session.day.day,
                rangeKey: rangeKey,
                targetRepsCSV: targetReps,
                actualRepsCSV: actualReps
            )
        )

        state.selectedRangeKey = rangeKey

        if isCurrentProgress(session),
           let nextSession = weeks.nextSession(after: session) {
            state.currentWeek = nextSession.week
            state.currentDay = nextSession.day.day
        }

        try? modelContext.save()
        resetSetProgress()
    }

    private func deleteCompletion(_ completion: WorkoutCompletion) {
        modelContext.delete(completion)
        try? modelContext.save()
    }

    private func isCompleted(_ session: RoutineSession) -> Bool {
        completions.contains {
            $0.week == session.week && $0.day == session.day.day
        }
    }

    private func isCurrentProgress(_ session: RoutineSession) -> Bool {
        state.currentWeek == session.week && state.currentDay == session.day.day
    }

    private var allSetsCompleted: Bool {
        completedSetIndexes.count == 5
    }

    private func toggleSet(index: Int, target: SetTarget, restSeconds: Int) {
        if completedSetIndexes.contains(index) {
            completedSetIndexes.remove(index)
            return
        }

        setInputs[index] = normalizedSetInput(index: index, target: target)
        completedSetIndexes.insert(index)

        if index < 4 {
            remainingRestSeconds = restSeconds
            isResting = true
        }
    }

    private func setInputBinding(index: Int, target: SetTarget) -> Binding<String> {
        Binding(
            get: {
                setInputs[index, default: "\(target.minimumReps)"]
            },
            set: { newValue in
                setInputs[index] = newValue.filter(\.isNumber)
            }
        )
    }

    private func normalizedSetInput(index: Int, target: SetTarget) -> String {
        let value = setInputs[index, default: "\(target.minimumReps)"]
        return value.isEmpty ? "\(target.minimumReps)" : value
    }

    private func tickRestTimer() {
        guard isResting else { return }

        if remainingRestSeconds > 1 {
            remainingRestSeconds -= 1
        } else {
            remainingRestSeconds = 0
            isResting = false
        }
    }

    private func timerDisplayText(restSeconds: Int) -> String {
        let displaySeconds = remainingRestSeconds == 0 ? restSeconds : remainingRestSeconds
        return "\(displaySeconds / 60):\(String(format: "%02d", displaySeconds % 60))"
    }

    private func toggleRestTimer(restSeconds: Int) {
        if isResting {
            isResting = false
            return
        }

        if remainingRestSeconds == 0 {
            remainingRestSeconds = restSeconds
        }

        isResting = true
    }

    private func resetRestTimer(restSeconds: Int) {
        remainingRestSeconds = restSeconds
        isResting = false
    }

    private func resetSetProgress() {
        completedSetIndexes.removeAll()
        setInputs.removeAll()
        remainingRestSeconds = 0
        isResting = false
        dismissKeyboard()
    }

    private func dismissKeyboard() {
        focusedSetIndex = nil
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            AppState.self,
            WorkoutCompletion.self
        ], inMemory: true)
}

private struct KeyboardDismissTapInstaller: UIViewRepresentable {
    let onTapOutsideTextInput: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapOutsideTextInput: onTapOutsideTextInput)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false

        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(in: view.window)
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTapOutsideTextInput = onTapOutsideTextInput
        context.coordinator.installIfNeeded(in: uiView.window)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTapOutsideTextInput: () -> Void
        private weak var recognizer: UITapGestureRecognizer?

        init(onTapOutsideTextInput: @escaping () -> Void) {
            self.onTapOutsideTextInput = onTapOutsideTextInput
        }

        func installIfNeeded(in window: UIWindow?) {
            guard recognizer == nil, let window else { return }

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
        }

        @objc private func handleTap() {
            onTapOutsideTextInput()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view: UIView? = touch.view

            while let currentView = view {
                if currentView is UITextField || currentView is UITextView {
                    return false
                }

                view = currentView.superview
            }

            return true
        }
    }
}
