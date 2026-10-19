import SwiftUI
import AppKit
import VisionHarnessCore

/// The "Connect a subscription plan" guide as a sheet.
struct PlanGuideView: View {
    let appModel: AppModel
    @State private var guide: PlanGuideModel
    @Environment(\.dismiss) private var dismiss

    init(request: PlanGuideRequest, appModel: AppModel) {
        self.appModel = appModel
        let guide = PlanGuideModel(backend: request.backend ?? LivePlanBackend(), config: appModel.config, planID: request.planID)
        request.stage?(guide)
        _guide = State(initialValue: guide)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                page
                    .padding(28)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
        .onAppear {
            guide.onSaved = { _ in appModel.transport.resetRouteCache() }
            guide.onFinish = {
                appModel.config.wizardCompleted = true
                appModel.mode = .chat
                if appModel.selectedSession == nil { appModel.newChat() }
                dismiss()
            }
            guide.onLeave = { dismiss() }
        }
        .onDisappear { guide.dispose() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(PlanPage.allCases, id: \.rawValue) { entry in
                    Capsule()
                        .fill(entry.rawValue <= guide.page.rawValue ? Color.accentColor : Theme.hairline)
                        .frame(height: 3)
                }
            }
            HStack {
                Text(guide.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(guide.stepText).font(Theme.metaFont).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button(guide.page == .plan ? "Cancel" : "Back") { guide.back() }
                .keyboardShortcut(.cancelAction)
                .disabled(guide.page == .done && guide.saving)
            Spacer()
            Button(guide.nextLabel) { guide.next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!guide.canAdvance)
        }
        .padding(14)
    }

    @ViewBuilder
    private var page: some View {
        switch guide.page {
        case .plan: PlanChoicePage(guide: guide)
        case .key: PlanKeyPage(guide: guide)
        case .paste: PlanPastePage(guide: guide)
        case .check: PlanCheckPage(guide: guide)
        case .model: PlanModelPage(guide: guide)
        case .use: PlanUsePage(guide: guide)
        case .done: PlanDonePage(guide: guide)
        }
    }
}

// MARK: - 1. Which plan?

struct PlanChoicePage: View {
    @Bindable var guide: PlanGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideIcon(systemName: "creditcard")
            GuideHeading("Which plan?")
            GuideLead("Vision can use a coding subscription or a pay-as-you-go API from these services. Pick the one you have — or want.")
            ForEach(PlanCatalog.plans) { plan in
                GuideChoice(systemImage: icon(plan), title: plan.name, detail: plan.summary,
                            selected: guide.plan?.id == plan.id) { guide.choose(plan.id) }
            }
            if let plan = guide.plan, plan.regions.count > 2 {
                // Z.ai: which endpoint the key is for — the Coding Plan, the per-token API, or either in China.
                GuideField(label: plan.regionLabel, hint: "A GLM Coding Plan key works only on the Coding Plan endpoint; a key made at open.bigmodel.cn only on the China ones. Not sure? Pick one — the check says if another fits.") {
                    Picker(plan.regionLabel, selection: $guide.regionID) {
                        ForEach(plan.regions) { region in Text(region.name).tag(region.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                }
                if let detail = guide.region?.detail {
                    GuideAside(detail + " · " + (guide.region?.baseURL ?? ""))
                }
            } else if let plan = guide.plan, plan.regions.count > 1 {
                GuideField(label: plan.regionLabel, hint: "Where your account is. A key works only in its own region.") {
                    Picker(plan.regionLabel, selection: $guide.regionID) {
                        ForEach(plan.regions) { region in Text(region.name).tag(region.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
            }
        }
    }

    private func icon(_ plan: SubscriptionPlan) -> String {
        plan.isSubscription ? "calendar.badge.clock" : "dollarsign.circle"
    }
}

// MARK: - 2. Get your key

struct PlanKeyPage: View {
    @Bindable var guide: PlanGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "key")
            GuideHeading("Get your key")
            if let plan = guide.plan, let region = guide.region {
                GuideLead("\(plan.name) — \(region.name).")
                GuideSteps(items: plan.keySteps(region: region))
                Button("Open \(region.keyPage.host ?? "the key page")") { guide.openKeyPage() }
                    .buttonStyle(.borderedProminent)
                GuideNote(.info, plan.keyHint, title: "What the key looks like")
                GuideNote(.warning, plan.terms, title: "The plan's terms")
                GuideAside("The key goes to your Keychain, never into Vision's settings file.")
            }
        }
    }
}

// MARK: - 3. Paste your key

struct PlanPastePage: View {
    @Bindable var guide: PlanGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "lock.rectangle")
            GuideHeading("Paste your key")
            GuideField(label: "API key", hint: guide.plan?.keyHint) {
                SecureField("Paste the key here", text: $guide.key)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
            }
            if let problem = guide.keyProblem {
                GuideNote(.warning, problem)
            }
            GuideAside("Stored in your Keychain and only used to call \(guide.region?.baseURL ?? "the plan's API") from this Mac.")
        }
    }
}

// MARK: - 4. Check it

struct PlanCheckPage: View {
    @Bindable var guide: PlanGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "checkmark.shield")
            GuideHeading("Check it")
            GuideLead(guide.plan?.checksWithChat == true
                      ? "Vision sends \(guide.region?.baseURL ?? "the endpoint") a one-word message with the key."
                      : "Vision asks \(guide.region?.baseURL ?? "the plan") which models the key can use (or, where that isn't offered, sends it a one-word message).")
            if guide.checking {
                GuideBusy("Checking the key…")
            } else if let error = guide.checkError {
                GuideNote(.error, error, title: "Not working yet") {
                    HStack {
                        if let suggested = guide.suggestedRegion,
                           let name = guide.plan?.regions.first(where: { $0.id == suggested })?.name {
                            Button("Switch to \(name)") { guide.switchToSuggested() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Try Again") { guide.runCheck() }
                    }
                }
            } else if guide.checked {
                GuideNote(.success, guide.listed.map { "The key works — \($0.count) model\($0.count == 1 ? "" : "s") available." } ?? "The key works.")
            }
        }
    }
}

// MARK: - 5. Pick the model

struct PlanModelPage: View {
    @Bindable var guide: PlanGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideIcon(systemName: "cpu")
            GuideHeading("Pick the model")
            GuideLead(guide.listed == nil ? "The plan's models. The recommended one is first." : "The models the key can use. The recommended one is first.")
            ForEach(Array(guide.models.prefix(40).enumerated()), id: \.element.id) { index, model in
                GuideChoice(systemImage: index == 0 ? "star" : "cpu",
                            title: model.id + (index == 0 ? " — Recommended" : ""),
                            detail: [model.note, guide.contextText(model)].compactMap { $0 }.joined(separator: " · "),
                            selected: guide.selectedModel == model.id) { guide.pick(model.id) }
            }
        }
    }
}

// MARK: - 6. How Vision uses it

struct PlanUsePage: View {
    @Bindable var guide: PlanGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideIcon(systemName: "person.3")
            GuideHeading("How should Vision use it?")
            ForEach(PlanRole.allCases) { role in
                GuideChoice(systemImage: role.icon, title: role.title, detail: role.detail,
                            selected: guide.role == role) { guide.role = role }
            }
            if guide.plan?.interactiveOnly == true {
                GuideNote(.info, "This plan is for interactive use only: the task queue and other unattended work won't run on it while it's the primary.")
            }
            GuideSubheading("Privacy")
            Toggle(isOn: $guide.isPrivate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(guide.isPrivate ? "Private" : "Not private — this is an online service").font(.callout.weight(.medium))
                    Text("Vision masks sensitive details before sending (see Settings ▸ AI Models ▸ Sensitive data). Switch this on only if you're sure the service may see everything.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }
}

// MARK: - 7. Done

struct PlanDonePage: View {
    @Bindable var guide: PlanGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "checkmark.circle")
            GuideHeading("Done")
            if let route = guide.saved {
                GuideNote(.success, "Saved \(route.name) — \(route.model), with its key in your Keychain.")
            }
            if guide.saving {
                GuideBusy("Sending a first message…")
            } else if let hello = guide.hello {
                GuideNote(.success, hello, title: "\(guide.saved?.name ?? "The model") answered")
            } else if let error = guide.helloError {
                GuideNote(.error, error, title: "The first message didn't go through") {
                    Button("Try Again") { guide.sayHello() }
                }
            }
            GuideBullets(items: [
                ("person.3", "**Settings ▸ AI Models** decides who answers, who helps, who takes over, and who is private."),
                ("eye.slash", "**Sensitive data** is masked before it reaches a model that isn't private."),
            ])
        }
    }
}

// MARK: - The live backend

@MainActor
final class LivePlanBackend: PlanGuideBackend {
    func listModels(route: ProviderProfile) async throws -> [String] {
        try await ProviderClients.make(route).listModels()
    }

    func ping(route: ProviderProfile, model: String) async throws {
        let client = ProviderClients.make(route)
        let request = LLMRequest(systemPrompt: "", messages: [.user("Hi")], tools: [], model: model,
                                 maxTokens: 1, thinking: .off)
        for try await _ in client.stream(request) {}
    }

    func sayHello(route: ProviderProfile) async throws -> String {
        try await GuideHello.say(through: route,
                                 prompt: "Say hello to someone who just connected their coding app to your service, in one short, friendly sentence.")
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
