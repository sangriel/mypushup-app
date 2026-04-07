import SwiftData
import SwiftUI

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

    var body: some View {
        List {
            if let session {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: session)
                        rangePicker(for: session)

                        if let sets = selectedSets(for: session) {
                            setsView(sets: sets, restSeconds: session.day.restSeconds)
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
                HStack {
                    Text("Set \(index + 1)")
                        .font(.headline)
                    Spacer()
                    Text(target.displayText)
                        .font(.title3.monospacedDigit().bold())
                    Text("회")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }

            Text("마지막 세트의 + 표시는 가능한 만큼 추가 수행한다는 뜻입니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
        .disabled(isCompleted(session))
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

        modelContext.insert(
            WorkoutCompletion(
                week: session.week,
                day: session.day.day,
                rangeKey: rangeKey,
                targetRepsCSV: targetReps
            )
        )

        state.selectedRangeKey = rangeKey

        if let nextSession = weeks.nextSession(after: session) {
            state.currentWeek = nextSession.week
            state.currentDay = nextSession.day.day
        }

        try? modelContext.save()
    }

    private func isCompleted(_ session: RoutineSession) -> Bool {
        completions.contains {
            $0.week == session.week && $0.day == session.day.day
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            AppState.self,
            WorkoutCompletion.self
        ], inMemory: true)
}
