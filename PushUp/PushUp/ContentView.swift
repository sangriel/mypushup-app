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
                    DashboardView(
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

private struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
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
            if let session {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: session)
                        rangePicker(for: session)

                        if let sets = selectedSets(for: session) {
                            setsView(sets: sets, restSeconds: session.day.restSeconds)
                            restTimerView()
                            completeButton(for: session, sets: sets)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "모든 루틴 완료",
                        systemImage: "checkmark.seal",
                        description: Text("6주 프로그램의 마지막 세션까지 완료했습니다.")
                    )
                }
            }

            if !completions.isEmpty {
                Section("최근 완료 기록") {
                    ForEach(completions.prefix(8)) { completion in
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
        .onChange(of: session) { _, _ in
            resetSetProgress()
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
    }

    private var session: RoutineSession? {
        guard let currentSession = weeks.session(week: state.currentWeek, day: state.currentDay) ?? weeks.firstSession() else {
            return nil
        }

        if isCompleted(currentSession) {
            return weeks.nextSession(after: currentSession)
        }

        return currentSession
    }

    private func header(for session: RoutineSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("오늘의 루틴")
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
    private func restTimerView() -> some View {
        if isResting {
            HStack {
                Label("휴식 \(remainingRestSeconds)초", systemImage: "timer")
                    .font(.headline.monospacedDigit())

                Spacer()

                Button("건너뛰기") {
                    remainingRestSeconds = 0
                    isResting = false
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func completeButton(for session: RoutineSession, sets: RoutineSets) -> some View {
        Button {
            complete(session: session, sets: sets)
        } label: {
            Label("오늘 루틴 완료", systemImage: "checkmark.circle.fill")
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

        if let nextSession = weeks.nextSession(after: session) {
            state.currentWeek = nextSession.week
            state.currentDay = nextSession.day.day
        }

        try? modelContext.save()
        resetSetProgress()
    }

    private func isCompleted(_ session: RoutineSession) -> Bool {
        completions.contains {
            $0.week == session.week && $0.day == session.day.day
        }
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
