import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case english
    case chinese

    var id: String { rawValue }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        return Locale.current.language.languageCode?.identifier == "zh" ? .chinese : .english
    }
}

struct L10n: Sendable {
    let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language.resolved
    }

    func text(_ english: String, _ chinese: String) -> String {
        language == .chinese ? chinese : english
    }

    private func normalizedPriceProviderNames(_ providerNames: [String]) -> [String] {
        Array(Set(providerNames.compactMap { providerName in
            let trimmed = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var apiEquivalentEstimate: String { text("Today · estimated API cost", "今天 · API 费用估算") }
    var unknownPricingTooltip: String { text("Some models have no matching price. Their usage is excluded from the cost total and budget, so the estimate may be understated.", "部分模型没有匹配的价格。它们的用量未计入费用总额和预算，因此估算金额可能被低估。") }
    var mixedPricingTooltip: String { text("This estimate combines custom pricing with other model results; unknown-priced usage is excluded from the total and budget, so it may be understated.", "此费用估算混合使用了自定义价格和其他模型结果；未知价格用量未计入总额和预算，金额可能被低估。") }
    var today: String { text("Today", "今天") }
    var input: String { text("Input", "输入") }
    var output: String { text("Output", "输出") }
    var cacheRead: String { text("Cache read", "缓存读取") }
    var cacheWrite: String { text("Cache write", "缓存写入") }
    var prompt: String { text("prompt", "提示词") }
    var generated: String { text("generated", "生成") }
    var reused: String { text("reused", "复用") }
    var allSources: String { text("all sources", "全部来源") }
    var usageByDay: String { text("Usage by day", "每日用量") }
    var dailyTotals: String { text("Daily totals", "每日总量") }
    var tokens: String { text("Tokens", "Token") }
    var totalTokens: String { text("Total tokens", "Token 总量") }
    var cost: String { text("Cost", "费用") }
    var agent: String { text("Agent", "Agent") }
    var agents: String { text("Agents", "Agent 数") }
    var model: String { text("Model", "模型") }
    var agentSummary: String { text("Agent summary", "Agent 汇总") }
    var noAgentUsage: String { text("No agent usage in this period", "这段时间没有 Agent 用量") }
    var waitingRefresh: String { text("Waiting for the first usage refresh", "等待首次用量刷新") }
    var refreshUsage: String { text("Refresh usage", "刷新用量") }
    var updatePricing: String { text("Update pricing", "更新价格") }
    var customPricing: String { text("Custom price list", "自定义价目表") }
    var importCustomPricing: String { text("Import price list", "导入价目表") }
    var importAndMergeCustomPricing: String { text("Import and merge", "导入并合并") }
    var mergeCustomPricingMessage: String {
        text(
            "Add new models and update supplied rates; existing models and omitted fields are kept.",
            "新增模型并更新文件中提供的价格；已有模型和未提供的字段会保留。"
        )
    }
    var replaceCustomPricing: String { text("Replace price list", "整体替换价目表") }
    var replaceCustomPricingMessage: String { text("Use only the selected LiteLLM-style JSON price list.", "只使用选中的 LiteLLM 格式 JSON 价目表。") }
    var exportCustomPricing: String { text("Export price list", "导出价目表") }
    var exportCustomPricingMessage: String { text("Save a LiteLLM-compatible price list to share.", "保存兼容 LiteLLM 的价目表，方便分享。") }
    var customPricingFileName: String { "ccusage-custom-pricing.json" }
    var searchModels: String { text("Search models…", "搜索模型…") }
    var modelCatalogTitle: String { text("Model catalog", "模型目录") }
    var modelCatalogRecordCount: String { text("Records", "记录") }
    var modelCatalogProviderCount: String { text("Providers", "Provider") }
    var modelCatalogSource: String { text("Source", "来源") }
    var modelCatalogCustomSource: String { text("Custom", "自定义") }
    var modelCatalogRemoteSource: String { text("Remote catalog", "远程目录") }
    var modelCatalogProviderID: String { text("Catalog provider", "目录 Provider") }
    var modelCatalogRecordIdentity: String { text("Record identity", "记录身份") }
    var modelCatalogWaiting: String { text("Waiting for the first catalog refresh.", "等待首次模型目录刷新。") }
    var modelCatalogSearchPrompt: String { text("Search model, provider, capability…", "搜索模型、Provider、能力…") }
    var modelCatalogSubtitle: String {
        text(
            "Browse imported models, pricing, limits, and capabilities.",
            "浏览已导入模型的价格、限制和能力。"
        )
    }
    var modelCatalogFilters: String { text("Filters", "筛选") }
    var modelCatalogClearFilters: String { text("Clear filters", "清除筛选") }
    var modelCatalogProviderFilter: String { text("Provider", "Provider") }
    var modelCatalogAllProviders: String { text("All providers", "全部 Provider") }
    var modelCatalogModalityFilter: String { text("Modality", "模态") }
    var modelCatalogAnyModality: String { text("Any modality", "全部模态") }
    var modelCatalogCapabilityFilter: String { text("Capability", "能力") }
    var modelCatalogAnyCapability: String { text("Any capability", "全部能力") }
    var modelCatalogPriceFilter: String { text("Input price / 1M", "输入价格 / 100 万") }
    var modelCatalogAnyPrice: String { text("Any price", "全部价格") }
    var modelCatalogPriceUnder1: String { "< $1" }
    var modelCatalogPrice1To5: String { "$1–$5" }
    var modelCatalogPrice5To20: String { "$5–$20" }
    var modelCatalogPriceOver20: String { "≥ $20" }
    var modelCatalogContextFilter: String { text("Max context", "最大上下文") }
    var modelCatalogAnyContext: String { text("Any context", "全部上下文") }
    var modelCatalogContextUnder32: String { "< 32K" }
    var modelCatalogContext32To128: String { "32K–128K" }
    var modelCatalogContext128To200: String { "128K–200K" }
    var modelCatalogContextOver200: String { "≥ 200K" }
    var modelCatalogNoResults: String { text("No matching models", "没有匹配的模型") }
    var modelCatalogSelect: String { text("Select a model to inspect its pricing and metadata.", "选择模型查看价格和属性。") }
    var modelCatalogPricing: String { text("Pricing per 1M tokens", "每 100 万 tokens 的价格") }
    var modelCatalogReferencePricing: String { text("Imported tiered rates (reference)", "导入的分层价格（参考）") }
    var modelCatalogReferencePricingNote: String {
        text(
            "These tiered rates are preserved from the imported catalog for reference; the monitor's custom overlay uses the four base rates above.",
            "这些分层价格来自导入的目录，仅供参考；监视器的自定义覆盖目前使用上面的四种基础价格。"
        )
    }
    var modelCatalogLimits: String { text("Limits", "限制") }
    var modelCatalogCapabilities: String { text("Capabilities", "能力") }
    var modelCatalogDetails: String { text("Details", "详情") }
    var modelCatalogProvider: String { text("Provider", "Provider") }
    var modelCatalogRoute: String { text("Route", "路由") }
    var modelCatalogMode: String { text("Mode", "模式") }
    var modelCatalogContext: String { text("Max input", "最大输入") }
    var modelCatalogMaxOutput: String { text("Max output", "最大输出") }
    var modelCatalogMaxTokens: String { text("Max tokens", "最大 tokens") }
    var modelCatalogModel: String { text("Model", "模型") }
    var modelCatalogDescription: String { text("Description", "描述") }
    var modelCatalogModality: String { text("Modality", "模态") }
    var modelCatalogVersion: String { text("Version", "版本") }
    var modelCatalogNoValue: String { "—" }
    func modelCatalogModels(_ visible: Int, _ total: Int) -> String {
        text("\(visible) of \(total) models", "\(visible) / \(total) 个模型")
    }
    var modelCatalogVision: String { text("Vision", "视觉") }
    var modelCatalogFunctionCalling: String { text("Function calling", "函数调用") }
    var modelCatalogReasoning: String { text("Reasoning", "推理") }
    var modelCatalogPromptCaching: String { text("Prompt caching", "Prompt 缓存") }
    var modelCatalogToolChoice: String { text("Tool choice", "工具选择") }
    var modelCatalogStructuredOutput: String { text("Structured output", "结构化输出") }
    var modelCatalogPDF: String { "PDF" }
    var modelCatalogAudio: String { text("Audio", "音频") }
    var modelCatalogComputerUse: String { text("Computer use", "电脑操作") }
    var modelCatalogWebSearch: String { text("Web search", "网页搜索") }
    var noCustomPricingToExport: String { text("There is no custom price list to export.", "当前没有可导出的自定义价目表。") }
    var customPricingImportFallbackTitle: String { text("Using selected file", "已使用选中的文件") }
    var customPricingImportFallbackMessage: String {
        text(
            "The app-owned copy could not be saved, so the selected file is being used as the active price list.",
            "应用自己的价目表副本无法保存，因此已使用选中的文件作为当前价目表。"
        )
    }
    var customPricingMergeFallbackTitle: String { text("Could not save merged list", "无法保存合并后的价目表") }
    var customPricingMergeFallbackMessage: String {
        text(
            "The merged list could not be saved. Replace the current list with the selected file instead?",
            "合并后的价目表无法保存。是否改为用选中的文件整体替换当前价目表？"
        )
    }
    var replaceAnyway: String { text("Replace anyway", "仍然整体替换") }
    var cancel: String { text("Cancel", "取消") }
    var ok: String { text("OK", "好") }
    var removeCustomPricing: String { text("Remove price list", "移除价目表") }
    var chooseCustomPricing: String { text("Choose custom price list", "选择自定义价目表") }
    var chooseCustomPricingMessage: String { text("Select a LiteLLM-style JSON price list.", "选择 LiteLLM 格式的 JSON 价目表。") }
    var customPricingUnavailable: String { text("Invalid price list", "价目表无效") }
    var notConfigured: String { text("Not configured", "未配置") }
    var budget: String { text("Budgets", "额度") }
    var dailyBudget: String { text("Daily budget", "每日额度") }
    var monthlyBudget: String { text("Monthly budget", "每月额度") }
    var budgetInputMessage: String { text("Enter a USD amount. Leave it empty to disable the alert.", "输入美元金额。留空可关闭告警。") }
    var invalidBudgetMessage: String { text("Enter a finite number greater than or equal to zero.", "请输入大于等于零的有限数字。") }
    var budgetAlertThreshold: String { text("Alert threshold", "告警阈值") }
    var budgetAlertThresholdInputMessage: String { text("Enter a percentage from 1 to 100.", "请输入 1 到 100 之间的百分比。") }
    var budgetSettingsTitle: String { text("Budget alerts", "额度告警") }
    var budgetSettingsSubtitle: String {
        text(
            "Set daily and monthly limits, then choose when the alert turns red.",
            "设置每日和每月额度，并选择何时显示红色告警。"
        )
    }
    var budgetPreview: String { text("Preview", "预览") }
    var budgetPreviewExample: String {
        text(
            "The preview uses the larger configured limit; when none is set, it uses $100.",
            "预览使用已配置的较大额度；未设置时使用 $100。"
        )
    }
    var budgetPreviewNormal: String { text("Below threshold", "低于阈值") }
    var budgetPreviewAlert: String { text("At threshold", "达到阈值") }
    func budgetAlertWithIncompletePricing(_ label: String) -> String {
        text(
            "\(label); unknown-priced usage is excluded; total may be understated",
            "\(label)；未知价格用量未计入，金额可能被低估"
        )
    }
    var budgetDataIncomplete: String {
        text(
            "Incomplete: unknown-priced usage is excluded; total may be understated",
            "数据不完整：未知价格用量未计入，金额可能被低估"
        )
    }
    var noBudgetData: String { text("Waiting for monthly data", "等待月度数据") }
    func budgetAlertLabel(_ percentage: String) -> String {
        text("Alert at \(percentage)%", "达到 \(percentage)% 告警")
    }
    var customPriceSource: String { text("Custom", "自定义") }
    var approximatePriceSource: String { text("Approximate", "近似") }
    var ccusagePriceSource: String { "ccusage" }
    var approximatePricingTooltip: String {
        text(
            "A compatible ccusage tier was selected, but the imported price table has additional or different thresholds.",
            "已选择 ccusage 可表达的 tier，但导入价目表包含额外或不同的 threshold。"
        )
    }
    var pricingStatusApproximate: String { text("Price needs review", "价格需确认") }
    var pricingStatusStale: String { text("Pricing needs update", "价格需要更新") }
    var pricingStatusUnknown: String { text("Price unknown", "价格未知") }
    var pricingStatusMixed: String { text("Mixed pricing", "混合价格") }
    var pricingStatusDetails: String { text("Pricing details", "价格详情") }
    var pricingStatusExpandHint: String { text("Click to show pricing details", "点击查看价格详情") }
    var pricingStatusCollapseHint: String { text("Click to hide pricing details", "点击收起价格详情") }
    var pricingStatusApproximateDescription: String {
        text(
            "A compatible tier is used because the imported schedule has a threshold ccusage cannot represent exactly.",
            "导入价目表包含 ccusage 无法精确表达的 threshold，当前使用兼容 tier 估算。"
        )
    }
    var pricingStatusStaleDescription: String {
        text(
            "The model catalog changed. Refresh pricing to recalculate this estimate with the current rates.",
            "模型目录已经变化。请更新价格，使用当前价格重新计算这份估算。"
        )
    }
    var pricingStatusUnknownDescription: String {
        text(
            "Some model prices are unknown, so that usage is excluded from the total and budget. The estimate may be understated.",
            "部分模型价格未知，因此这些用量未计入总额和预算，估算金额可能被低估。"
        )
    }
    var pricingStatusUnknownMixedDescription: String {
        text(
            "Some model prices are unknown and excluded from the total and budget; other models may use different pricing sources.",
            "部分模型价格未知且未计入总额和预算；其他模型可能使用不同的价格来源。"
        )
    }
    var pricingStatusMixedDescription: String {
        text(
            "This estimate combines pricing from multiple sources.",
            "此估算混合使用了多个价格来源。"
        )
    }
    var pricingStatusNoModelDetails: String {
        text("No model details are available for this snapshot.", "此快照没有可显示的模型详情。")
    }
    func pricingStatusReason(
        _ reason: PricingStatusReason,
        missingRateComponents: [PricingStatusRateComponent]
    ) -> String {
        switch reason {
        case .customRatesIncomplete:
            return text(
                "Custom pricing is missing a rate used by this model.",
                "自定义价目表缺少本次使用所需的价格字段。"
            )
        case .catalogEntryMissing:
            return text(
                "The model is not matched in the active catalog.",
                "当前目录没有匹配到这个模型。"
            )
        case .catalogEntryDisabled:
            return text(
                "The catalog entry is disabled.",
                "目录中的这个模型已被禁用。"
            )
        case .catalogEntriesAmbiguous:
            return text(
                "The catalog has multiple entries with different prices.",
                "目录中有多条价格不同的记录，无法安全选择。"
            )
        case .catalogRatesIncomplete:
            let labels = missingRateComponents.map { component in
                switch component {
                case .input: return text("input", "输入")
                case .output: return text("output", "输出")
                case .cacheCreation: return text("cache write", "缓存写入")
                case .cacheRead: return text("cache read", "缓存读取")
                }
            }.joined(separator: ", ")
            if labels.isEmpty {
                return text(
                    "The catalog entry does not contain a complete price schedule; null is not $0.",
                    "目录记录没有完整价格；null 不等于 0 元。"
                )
            }
            return text(
                "Catalog price missing for \(labels); null is not $0.",
                "目录缺少 \(labels) 价格；null 不等于 0 元。"
            )
        case .noPriceSource:
            return text(
                "No active price source is available.",
                "当前没有可用的价格来源。"
            )
        }
    }
    var pricingStatusSelectedTier: String { text("Selected tier", "已选 tier") }
    var pricingStatusBackendTier: String { text("Backend tier", "后端 tier") }
    var pricingStatusModels: String { text("Models", "模型") }
    var pricingStatusSource: String { text("Source", "来源") }
    func pricingStatusModelCount(_ count: Int) -> String {
        text("\(count) model\(count == 1 ? "" : "s")", "\(count) 个模型")
    }
    func pricingStatusMoreModels(_ count: Int) -> String {
        text("+\(count) more model\(count == 1 ? "" : "s")", "还有 \(count) 个模型")
    }
    func pricingStatusTitle(_ kind: PricingStatusKind) -> String {
        switch kind {
        case .stale: return pricingStatusStale
        case .approximate: return pricingStatusApproximate
        case .unknown: return pricingStatusUnknown
        case .mixed: return pricingStatusMixed
        }
    }
    func pricingStatusDescription(_ kind: PricingStatusKind, includesMixedSources: Bool = false) -> String {
        switch kind {
        case .stale: return pricingStatusStaleDescription
        case .approximate: return pricingStatusApproximateDescription
        case .unknown: return includesMixedSources ? pricingStatusUnknownMixedDescription : pricingStatusUnknownDescription
        case .mixed: return pricingStatusMixedDescription
        }
    }
    func pricingStatusSourceLabel(
        _ source: ModelPricingSource,
        providerNames: [String] = []
    ) -> String {
        switch source {
        case .ccusage: return "ccusage"
        case .custom: return text("Custom", "自定义")
        case .remote: return priceListSourceLabel(providerNames)
        case .mixed: return text("Mixed sources", "混合来源")
        case .approximate: return text("Approximate", "近似")
        case .unknown: return text("Unknown", "未知")
        }
    }
    func priceListSourceLabel(_ providerNames: [String]) -> String {
        let names = normalizedPriceProviderNames(providerNames)
        guard !names.isEmpty else {
            return text("Pricing provider unavailable", "价目表提供方不可用")
        }
        return text(
            "\(names.joined(separator: ", ")) pricing",
            "\(names.joined(separator: "、")) 价目表"
        )
    }
    func priceListSourceTooltip(_ providerNames: [String]) -> String {
        let names = normalizedPriceProviderNames(providerNames)
        guard !names.isEmpty else {
            return text("The pricing provider name is unavailable.", "暂时无法识别价目表提供方。")
        }
        return text(
            "Pricing data provided by \(names.joined(separator: ", ")).",
            "价目表由 \(names.joined(separator: "、")) 提供。"
        )
    }
    func pricingStatusTierLabel(_ title: String, threshold: String) -> String {
        text("\(title) · \(threshold)", "\(title) · \(threshold)")
    }
    var approximateTierNote: String {
        text("Imported tier schedule · estimate uses the selected compatible tier", "导入的 tier 价格 · 估算使用选中的兼容 tier")
    }
    var officialAPIPrice: String { text("Official API reference price", "官方 API 参考价") }
    var officialAPIPriceTooltip: String {
        text(
            "ccusage calculated this total with its pricing data. Its JSON output does not include unit rates.",
            "ccusage 已使用其价目数据计算总费用；它的 JSON 输出没有提供单位价。"
        )
    }
    var noPricingAvailable: String { text("No pricing available", "暂无价格") }
    var unitPricingUnavailable: String { text("Unit rates unavailable; showing ccusage total", "ccusage 未提供单位价，以上为 ccusage 总费用") }
    var perMillionTokens: String { text("/ 1M tokens", "/ 100 万 tokens") }
    var selectedPricingTier: String { text("selected", "已选") }
    var disableAutomaticPricing: String { text("Disable automatic pricing", "关闭自动更新价格") }
    var enableAutomaticPricing: String { text("Enable automatic pricing", "开启自动更新价格") }
    var lookback: String { text("Lookback", "查看范围") }
    var currentMonth: String { text("This month", "本月") }
    var pricing: String { text("Pricing", "价格") }
    var refresh: String { text("refresh", "刷新") }
    var usageRefreshInterval: String { text("Usage refresh interval", "用量刷新间隔") }
    var autoRefreshShort: String { text("Auto-refresh", "自动刷新") }
    var usageSettings: String { text("Usage", "用量") }
    var sourceVerificationMode: String { text("Change detection", "变更检测") }
    var eventDrivenVerificationMode: String { text("Event-driven", "事件驱动") }
    var periodicFingerprintVerificationMode: String { text("Periodic check", "定期检查") }
    var sourceVerificationModeHelp: String {
        text(
            "Event-driven mode is cheapest and relies on the watcher. Periodic check mode keeps the watcher and also reads source metadata on a schedule; it runs ccusage only after a change is detected.",
            "事件驱动模式成本最低，依赖 watcher。定期检查模式会保留 watcher，并按时间读取源文件元数据；只有检测到变化后才运行 ccusage。"
        )
    }
    var usageRefreshIntervalHelp: String {
        text(
            "This is the minimum spacing between usage refreshes after a change is detected. It is not a fixed timer. It also controls watcher-down fallback, plugin refresh cadence, and the maximum dirty wait.",
            "这是检测到变化后两次用量刷新的最小间隔，不是固定的定时刷新；它也会影响 watcher 失效时的 fallback、插件刷新节奏和待刷新最长等待时间。"
        )
    }
    var fingerprintCheckInterval: String { text("Periodic check interval", "定期检查间隔") }
    var fingerprintCheckIntervalHelp: String {
        text(
            "Used only by periodic check mode. It adds a low-cost source-metadata scan; unchanged metadata does not run ccusage. A change may appear after this interval plus the normal refresh throttle.",
            "只用于定期检查模式。它会增加低成本的源文件元数据扫描；元数据未变化时不会运行 ccusage。变化可能需要等待此间隔加上正常刷新节流时间才显示。"
        )
    }
    var customFingerprintInterval: String { text("Custom check interval", "自定义检查间隔") }
    var customFingerprintIntervalPlaceholder: String { text("Minutes (1–60)", "分钟（1–60）") }
    var customFingerprintIntervalHelp: String { text("Enter a whole number of minutes from 1 to 60 for periodic source checks.", "请输入 1 到 60 之间的整数分钟数，用于定期检查源文件变化。") }
    var invalidFingerprintInterval: String { text("Invalid check interval", "检查间隔无效") }
    var days: String { text("days", "天") }
    var minutes: String { text("min", "分钟") }
    var seconds: String { text("sec", "秒") }
    var systemLanguage: String { text("System", "跟随系统") }
    var englishLanguage: String { "English" }
    var chineseLanguage: String { "中文" }
    var languageLabel: String { text("Language", "语言") }
    var ready: String { text("Ready", "就绪") }
    var statusHelp: String { text("This status reflects app health. Usage and pricing freshness are shown separately.", "此状态反映应用运行情况；用量和价格的新鲜度会单独显示。") }
    var updated: String { text("Updated", "更新于") }
    var justNow: String { text("Just now", "刚刚") }
    var changesPending: String { text("Changes pending", "等待变更") }
    var updatingUsage: String { text("Updating usage", "正在更新用量") }
    var updatingPricing: String { text("Updating pricing", "正在更新价格") }
    var waitingForUsage: String { text("Waiting for usage data", "等待用量数据") }
    var noSnapshot: String { text("No snapshot yet", "尚未生成快照") }
    var unknownPricingExcluded: String { text("Unknown pricing excluded from the total", "未知价格未计入总额") }
    var agentDetail: String { text("Agent detail", "Agent 明细") }
    var modelDetail: String { text("Model detail", "模型明细") }
    var basePricingTier: String { text("Base", "基础") }
    var longContextPricingTier: String { text("Long context", "长上下文") }
    var above: String { text("above", "超过") }
    var tokensShort: String { text("tokens", "tokens") }
    var inputShort: String { text("input", "输入") }
    var outputShort: String { text("output", "输出") }
    var cacheReadShort: String { text("read", "读") }
    var cacheWriteShort: String { text("write", "写") }
    var cacheShort: String { text("cache", "缓存") }
    var noDetailForDate: String { text("No detail for this date", "这一天没有明细") }
    var moreModels: String { text("more models", "个更多模型") }
    var expandOtherModels: String { text("Expand other models", "展开其他模型") }
    var collapseOtherModels: String { text("Collapse other models", "收起其他模型") }
    var models: String { text("Models", "模型") }
    var notificationFeedTitle: String { text("Notifications", "通知") }
    var notificationFeedEnabled: String { text("In-app notifications", "应用内通知") }
    var notificationFeedOpen: String { text("Open notifications", "打开通知") }
    var notificationFeedClosed: String { text("Notifications closed", "通知已关闭") }
    var notificationFeedClose: String { text("Close notifications", "关闭通知") }
    var notificationFeedDisabled: String { text("In-app notifications are disabled. Event collection continues.", "应用内通知已关闭；事件收集仍会继续。") }
    var notificationFeedEmpty: String { text("No notifications yet.", "暂无通知。") }
    var notificationFeedEmptySubtitle: String { text("You're all caught up.", "你已经处理完所有通知。") }
    var notificationFeedNoUnread: String { text("No unread notifications.", "没有未读通知。") }
    var notificationFeedMarkAllRead: String { text("Mark all read", "全部标为已读") }
    var notificationFeedMarkRead: String { text("Mark as read", "标为已读") }
    var notificationFeedDismiss: String { text("Dismiss notification", "关闭通知") }
    var notificationFeedClearAll: String { text("Clear all", "清空全部") }
    var notificationFeedClearAllHelp: String { text("Remove all notifications from this list", "从列表中移除全部通知") }
    var notificationFeedAll: String { text("All", "全部") }
    var notificationFeedUnread: String { text("Unread", "未读") }
    var notificationFeedSourceModelCatalog: String { text("Model catalog", "模型目录") }
    var notificationFeedSourceTestPlugin: String { text("Test plugin", "测试插件") }
    var notificationFeedSourceInternal: String { text("Meterlark", "Meterlark") }
    var notificationFeedSourcePlugin: String { text("Plugin", "插件") }
    func notificationFeedEventType(_ type: NotificationEventType) -> String {
        if type == .modelAdded { return text("Added", "新增") }
        if type == .modelRemoved { return text("Removed", "下架") }
        if type == .modelEnabled { return text("Enabled", "启用") }
        if type == .modelDisabled { return text("Disabled", "停用") }
        if type == .pricingChanged { return text("Pricing", "价格") }
        return text("Update", "更新")
    }
    func notificationFeedEventTitle(_ type: NotificationEventType, fallback: String) -> String {
        if type == .modelAdded { return text("Model added", "模型已新增") }
        if type == .modelRemoved { return text("Model removed", "模型已下架") }
        if type == .modelEnabled { return text("Model enabled", "模型已启用") }
        if type == .modelDisabled { return text("Model disabled", "模型已停用") }
        if type == .pricingChanged { return text("Model pricing changed", "模型价格已变化") }
        if type == .catalogUpdated { return text("Model catalog updated", "模型目录已更新") }
        return fallback
    }
    func notificationFeedUnreadCount(_ count: Int) -> String {
        text("\(count) unread", "\(count) 条未读")
    }

    func notificationFeedCatalogSummary(_ summary: NotificationCatalogChangeSummary) -> String {
        let parts = [
            summary.added > 0 ? text("added: \(summary.added)", "新增：\(summary.added)") : nil,
            summary.removed > 0 ? text("removed: \(summary.removed)", "下架：\(summary.removed)") : nil,
            summary.enabled > 0 ? text("enabled: \(summary.enabled)", "启用：\(summary.enabled)") : nil,
            summary.disabled > 0 ? text("disabled: \(summary.disabled)", "停用：\(summary.disabled)") : nil,
            summary.pricingChanged > 0 ? text("pricing changed: \(summary.pricingChanged)", "价格变化：\(summary.pricingChanged)") : nil
        ].compactMap { $0 }.joined(separator: text(", ", "、"))
        return text(
            "\(summary.total) additional catalog changes (\(parts)).",
            "目录还有 \(summary.total) 项变化（\(parts)）。"
        )
    }
    func notificationFeedAccessibilityLabel(_ count: Int) -> String {
        count > 0
            ? text("Notifications, \(count) unread", "通知，\(count) 条未读")
            : text("Notifications", "通知")
    }
    var unknown: String { text("Unknown", "未知") }
    var chartView: String { text("Chart view", "图表视图") }
    var settingsLabel: String { text("Settings", "设置") }
    var plugins: String { text("Plugins", "插件") }
    var pluginSettings: String { text("Plugin settings", "插件设置") }
    var pluginSettingsTitle: String { text("Plugin Settings", "插件设置") }
    var dashboardSummary: String { text("Token summary", "Token 汇总") }
    var customizeDashboardLayout: String { text("Customize Dashboard layout", "自定义 Dashboard 布局") }
    var dashboardLayoutSettingsTitle: String { text("Dashboard Layout", "Dashboard 布局") }
    var dashboardLayoutPreviewTitle: String { text("Dashboard Preview", "Dashboard 预览") }
    var dashboardLayoutSubtitle: String {
        text(
            "Preview changes are live. Save to apply the draft to the main Dashboard; closing discards unsaved changes.",
            "预览会实时更新。点击保存才会应用到主 Dashboard；关闭窗口会丢弃未保存的修改。"
        )
    }
    var dashboardLayoutBuiltIn: String { text("Built-in component", "内置组件") }
    var dashboardLayoutPlugin: String { text("Active plugin component", "已启用插件组件") }
    var dashboardLayoutColumns: String { text("Columns", "列数") }
    var dashboardLayoutHeight: String { text("Dashboard height", "Dashboard 高度") }
    var dashboardLayoutFitContent: String { text("Fit content", "适应内容") }
    var dashboardLayoutFixedHeight: String { text("Fixed height", "固定高度") }
    var dashboardLayoutCustomHeight: String { text("Height", "高度") }
    var dashboardLayoutPoints: String { text("pt", "点") }
    var resetDashboardLayout: String { text("Reset Dashboard layout", "恢复 Dashboard 默认布局") }
    var saveDashboardLayout: String { text("Save Dashboard layout", "保存 Dashboard 布局") }
    var layoutMoveUp: String { text("Move up", "上移") }
    var layoutMoveDown: String { text("Move down", "下移") }
    var layoutSaved: String { text("Layout saved", "布局已保存") }
    var pluginSettingsSubtitle: String {
        text(
            "Configure installed providers. Credentials are stored in the macOS Keychain.",
            "配置已安装的 Provider。凭据只存储在 macOS 钥匙串中。"
        )
    }
    var activeProviders: String { text("Active providers", "已启用的 Provider") }
    var externalPlugins: String { text("External plugins", "外部插件") }
    var installExternalPlugin: String { text("Install / update plugin", "安装 / 更新插件") }
    var pasteExternalPlugin: String { text("Paste JSON…", "粘贴 JSON 安装…") }
    var pastePluginTitle: String { text("Install plugin from JSON", "粘贴 JSON 安装插件") }
    var pastePluginHelp: String {
        text(
            "Paste the complete plugin.json for an HTTP plugin. New plugins start disabled; configure and enable them in the plugin list.",
            "粘贴 HTTP 插件的完整 plugin.json。新插件安装后默认关闭，请在插件列表中配置并启用。"
        )
    }
    var pluginManifestJSON: String { text("Plugin JSON", "插件 JSON") }
    var pasteFromClipboard: String { text("Paste from clipboard", "从剪贴板粘贴") }
    var clipboardHasNoText: String { text("The clipboard does not contain text.", "剪贴板中没有文本。") }
    var installPlugin: String { text("Install", "安装") }
    func pastePluginError(_ error: Error) -> String {
        if error as? ExternalPluginRegistryError == .pastedManifestRequiresHTTP {
            return text(
                "Paste installation supports HTTP plugins. Install plugins with executable files from a package directory.",
                "粘贴安装支持 HTTP 插件。包含脚本或可执行文件的插件请通过文件夹安装。"
            )
        }
        if error as? PluginPackageValidationError == .unreadableManifest {
            return text("Paste valid JSON for a complete plugin.json.", "请粘贴完整且格式正确的 plugin.json。")
        }
        if error as? PluginPackageValidationError == .manifestTooLarge {
            return text("Plugin JSON must be 512 KiB or smaller.", "插件 JSON 不能超过 512 KiB。")
        }
        return error.localizedDescription
    }
    var externalPluginInstallMessage: String {
        text(
            "Choose an external plugin package directory. The package is validated before it is installed and starts disabled.",
            "选择外部插件包目录。安装前会校验包内容，安装后默认关闭。"
        )
    }
    var externalPluginEnable: String { text("Enable", "启用") }
    var externalPluginDisabled: String { text("Disabled by default", "默认关闭") }
    var noExternalPlugins: String { text("No external plugins installed.", "尚未安装外部插件。") }
    var externalPluginInvalid: String { text("Invalid package", "插件包无效") }
    var externalPluginNotActive: String { text("Installed, not active", "已安装但未启用") }
    var externalPluginMixed: String { text("Some plugins need attention", "部分插件需要处理") }
    var pluginDiscoveryIssues: String { text("Ignored plugin packages", "已忽略的插件包") }
    var configurePlugin: String { text("Configure", "配置") }
    func pluginConfigurationTitle(_ pluginName: String) -> String {
        text("Configure \(pluginName)", "配置 \(pluginName)")
    }
    var pluginConfigurationSubtitle: String {
        text(
            "Values are validated by the host. Secret fields are stored in the macOS Keychain.",
            "值由宿主校验。Secret 字段只存储在 macOS 钥匙串中。"
        )
    }
    var pluginConfigurationSave: String { text("Save configuration", "保存配置") }
    var pluginConfigurationReset: String { text("Reset configuration", "重置配置") }
    var pluginConfigurationSaved: String { text("Configuration saved", "配置已保存") }
    var pluginConfigurationRequired: String { text("Required", "必填") }
    var pluginConfigurationSecretConfigured: String { text("Secret configured", "Secret 已配置") }
    var pluginConfigurationSecretNotConfigured: String { text("Secret not configured", "Secret 未配置") }
    var pluginConfigurationClearSecret: String { text("Clear", "清除") }
    var pluginConfigurationKeepSecret: String { text("Keep", "保留") }
    var refreshPlugins: String { text("Refresh plugins", "刷新插件") }
    var configured: String { text("Configured", "已配置") }
    var done: String { text("Done", "完成") }
    var pluginIdle: String { text("Idle", "空闲") }
    var pluginLoading: String { text("Loading", "加载中") }
    var pluginReady: String { text("Ready", "就绪") }
    var pluginUnavailable: String { text("Unavailable", "不可用") }
    var pluginStale: String { text("Stale", "已过期") }
    var pluginFailed: String { text("Failed", "失败") }
    var developerSettings: String { text("Developer", "开发者") }
    var developerMode: String { text("Developer Mode", "开发者模式") }
    var developerModeHelp: String {
        text(
            "Shows watcher, fallback, refresh, and scheduler diagnostics. Adds one low-frequency health probe every 15 minutes while enabled.",
            "显示 watcher、fallback、刷新和调度器诊断信息。开启后每 15 分钟执行一次低频健康探测。"
        )
    }
    var openDeveloperDiagnostics: String { text("Open Developer Diagnostics", "打开开发者诊断") }
    var generateNotificationTestEvents: String { text("Generate test notifications", "生成测试通知") }
    var generateNotificationTestEventsHelp: String {
        text(
            "Publishes a sample batch through the in-app notification feed.",
            "通过应用内通知 feed 发布一组示例事件。"
        )
    }
    var about: String { text("About", "关于") }
    var aboutWindowTitle: String { text("About Meterlark", "关于 Meterlark") }
    var aboutSubtitle: String { text("Local usage and pricing monitor", "本地用量与价格监视器") }
    var aboutDetails: String { text("API-equivalent estimates · No telemetry", "API 等价费用估算 · 不收集遥测") }
    var version: String { text("Version", "版本") }
    var build: String { text("Build", "构建") }
    var bundledCCUsage: String { text("Bundled ccusage", "内置 ccusage") }
    var bundledCCUsageHash: String { text("ccusage SHA-256", "ccusage SHA-256") }
    var developerDiagnosticsTitle: String { text("Developer Diagnostics", "开发者诊断") }
    var developerDiagnosticsSubtitle: String {
        text(
            "Runtime observability for source watching, refresh scheduling, and monthly budget reconciliation.",
            "查看源文件监听、刷新调度和月度额度同步的运行状态。"
        )
    }
    var developerDiagnosticsWatcher: String { text("Watcher", "Watcher") }
    var developerDiagnosticsHealthFallback: String { text("Health check / fallback", "健康探测 / fallback") }
    var developerDiagnosticsRefreshPipeline: String { text("Refresh pipeline", "刷新流水线") }
    var developerDiagnosticsMonthlyPricing: String { text("Monthly budget / pricing", "月度额度 / 价格") }
    var developerDiagnosticsScheduler: String { text("Scheduler", "调度器") }
    var developerDiagnosticsRuntime: String { text("Runtime", "运行时") }
    var developerDiagnosticsRunHealthCheck: String { text("Run health check", "运行健康探测") }
    var developerDiagnosticsCopy: String { text("Copy diagnostics", "复制诊断信息") }
    var developerDiagnosticsCopied: String { text("Copied", "已复制") }
    var developerDiagnosticsCapturedAt: String { text("Captured", "采集时间") }
    var developerDiagnosticsState: String { text("State", "状态") }
    var developerDiagnosticsMessage: String { text("Message", "信息") }
    var developerDiagnosticsRoots: String { text("Watched roots", "监听根目录") }
    var developerDiagnosticsStartAttempts: String { text("Start attempts", "启动尝试") }
    var developerDiagnosticsEvents: String { text("Events", "事件数") }
    var developerDiagnosticsStartedAt: String { text("Started", "启动时间") }
    var developerDiagnosticsLastEvent: String { text("Last event", "最近事件") }
    var developerDiagnosticsRetryAt: String { text("Retry at", "重试时间") }
    var developerDiagnosticsHealthProbes: String { text("Health probes", "健康探测次数") }
    var developerDiagnosticsLastProbe: String { text("Last probe", "最近探测") }
    var developerDiagnosticsProbeDuration: String { text("Probe duration", "探测耗时") }
    var developerDiagnosticsProbeStatus: String { text("Probe status", "探测结果") }
    var developerDiagnosticsFallbackScans: String { text("Fallback scans", "fallback 扫描") }
    var developerDiagnosticsLastFallback: String { text("Last fallback", "最近 fallback") }
    var developerDiagnosticsScanDuration: String { text("Scan duration", "扫描耗时") }
    var developerDiagnosticsConsecutiveFailures: String { text("Consecutive failures", "连续失败") }
    var developerDiagnosticsPhase: String { text("Phase", "阶段") }
    var developerDiagnosticsDirty: String { text("Dirty", "待刷新") }
    var developerDiagnosticsGeneration: String { text("Generation", "代数") }
    var developerDiagnosticsLastRefresh: String { text("Last refresh", "最近刷新") }
    var developerDiagnosticsRefreshStarted: String { text("Started", "开始") }
    var developerDiagnosticsRefreshCompleted: String { text("Completed", "完成") }
    var developerDiagnosticsRefreshDuration: String { text("Duration", "耗时") }
    var developerDiagnosticsRefreshError: String { text("Last error", "最近错误") }
    var developerDiagnosticsRefreshes12Hours: String { text("Refreshes · 12h", "刷新次数 · 12 小时") }
    var developerDiagnosticsFailures12Hours: String { text("Failures · 12h", "失败次数 · 12 小时") }
    var developerDiagnosticsMonthlyRefreshes12Hours: String { text("Monthly refreshes · 12h", "月度刷新次数 · 12 小时") }
    var developerDiagnosticsMonthlyFailures12Hours: String { text("Monthly failures · 12h", "月度失败次数 · 12 小时") }
    var developerDiagnosticsMonthlyLastRefresh: String { text("Monthly last refresh", "最近月度刷新") }
    var developerDiagnosticsMonthlyResult: String { text("Monthly result", "月度结果") }
    var developerDiagnosticsMonthlyError: String { text("Monthly error", "月度错误") }
    var developerDiagnosticsMonthlySnapshot: String { text("Monthly snapshot", "月度快照") }
    var developerDiagnosticsMonthlyInFlight: String { text("Monthly in flight", "月度刷新进行中") }
    var developerDiagnosticsMonthlyDue: String { text("Monthly due", "月度应刷新时间") }
    var developerDiagnosticsMonthlyRequested: String { text("Monthly requested", "月度刷新请求") }
    var developerDiagnosticsMonthlyProjection: String { text("Realtime projection", "实时投影") }
    var developerDiagnosticsMonthlyProjectionDay: String { text("Projection anchor day", "投影锚定日期") }
    var developerDiagnosticsMonthlyProjectedCost: String { text("Projected monthly cost", "实时月度费用") }
    var developerDiagnosticsMonthlyResolution: String { text("Monthly resolution", "月度取值路径") }
    var developerDiagnosticsPricingUpdated: String { text("Pricing updated", "价格更新时间") }
    var developerDiagnosticsPricingAttempt: String { text("Pricing attempt", "价格尝试时间") }
    var developerDiagnosticsLastSourceEvent: String { text("Last source event", "最近源事件") }
    var developerDiagnosticsScheduledCheck: String { text("Scheduled check", "计划检查") }
    var developerDiagnosticsVerificationMode: String { text("Detection mode", "检测模式") }
    var developerDiagnosticsFingerprintInterval: String { text("Fingerprint interval", "Fingerprint 间隔") }
    var developerDiagnosticsLastFingerprintCheck: String { text("Last fingerprint check", "最近 fingerprint 检查") }
    var developerDiagnosticsNextFingerprintCheck: String { text("Next fingerprint target", "下次 fingerprint 目标") }
    var developerDiagnosticsLastFingerprintDetection: String { text("Last detected change", "最近检测到变化") }
    var developerDiagnosticsSourceChangeCause: String { text("Change cause", "变化来源") }
    var developerDiagnosticsFingerprintOutcome: String { text("Fingerprint outcome", "Fingerprint 结果") }
    var developerDiagnosticsFingerprintPending: String { text("Fingerprint pending", "Fingerprint 待处理") }
    var developerDiagnosticsRefreshInterval: String { text("Usage interval", "用量间隔") }
    var developerDiagnosticsWatchdogInterval: String { text("Watchdog interval", "watchdog 间隔") }
    var developerDiagnosticsSettleInterval: String { text("Settle interval", "稳定等待") }
    var developerDiagnosticsVersion: String { text("App version", "应用版本") }
    var developerDiagnosticsBuild: String { text("App build", "应用构建") }
    var developerDiagnosticsCCUsage: String { text("Bundled ccusage", "内置 ccusage") }
    var developerDiagnosticsUnknown: String { text("Unknown", "未知") }
    var developerDiagnosticsRunning: String { text("Running", "运行中") }
    var developerDiagnosticsDegraded: String { text("Degraded", "已降级") }
    var developerDiagnosticsDown: String { text("Down", "已停止") }
    var developerDiagnosticsYes: String { text("Yes", "是") }
    var developerDiagnosticsNo: String { text("No", "否") }
    var developerDiagnosticsNotAvailable: String { text("n/a", "无") }
    var generalSettings: String { text("General", "常规") }
    var launchAtLogin: String { text("Launch at login", "开机自动启动") }
    var launchAtLoginNeedsApproval: String { text("approval required", "需要批准") }
    var launchAtLoginUnavailable: String { text("unavailable", "不可用") }
    var launchAtLoginApprovalTitle: String { text("Approval required", "需要批准开机启动") }
    var launchAtLoginApprovalMessage: String {
        text(
            "macOS registered Meterlark, but it needs your approval in System Settings → General → Login Items.",
            "macOS 已登记 Meterlark，但需要你在“系统设置 → 通用 → 登录项”中批准。"
        )
    }
    var openLoginItems: String { text("Open Login Items", "打开登录项") }
    func launchAtLoginError(_ reason: String) -> String {
        text(
            "macOS could not update the login item. You may need to allow Meterlark in System Settings → General → Login Items.\n\(reason)",
            "macOS 无法更新开机启动项。可能需要在“系统设置 → 通用 → 登录项”中允许 Meterlark。\n\(reason)"
        )
    }
    var refreshSettings: String { text("Refresh", "刷新") }
    var displaySettings: String { text("Display", "显示") }
    var interfaceTextSize: String { text("Interface text size", "界面字号") }
    var interfaceTextSizeHelp: String {
        text(
            "Scales the readable app content. The menu bar and macOS system menus keep their native size.",
            "调整应用内容的可读字号；菜单栏和 macOS 系统菜单保持系统字号。"
        )
    }
    var surfaceStyle: String { text("Surface style", "表面风格") }
    var solidSurfaceStyle: String { text("Solid color", "纯色") }
    var glassSurfaceStyle: String { text("Frosted glass", "毛玻璃") }
    var surfaceStyleHelp: String {
        text(
            "Choose a solid surface or a native macOS frosted-glass material for the app UI.",
            "选择纯色表面，或使用 macOS 原生毛玻璃材质作为应用界面背景。"
        )
    }
    func interfaceTextSizeLabel(_ size: InterfaceTextSize) -> String {
        let name: String
        switch size {
        case .standard: name = text("Standard", "标准")
        case .large: name = text("Large", "较大")
        case .extraLarge: name = text("Extra Large", "更大")
        case .largest: name = text("Largest", "特大")
        }
        return name + " (" + String(size.percentage) + "%)"
    }
    var appearance: String { text("Theme", "主题") }
    var automaticAppearance: String { text("Automatic", "自动") }
    var lightAppearance: String { text("Light", "浅色") }
    var darkAppearance: String { text("Dark", "深色") }
    var menuBarFormat: String { text("Menu bar format", "菜单栏格式") }
    var menuBarFormatPreview: String { text("Live preview", "实时预览") }
    var menuBarFormatPreviewHint: String { text("Preview uses $12.34 as a sample cost.", "预览使用 $12.34 作为示例费用。") }
    var menuBarFormatMessage: String {
        text(
            "Use [logo], [money], [money:plain], [money:0:plain] to [money:6:plain], [money:compact:plain], and number-only [cost] tokens. Adjacent text and cost tokens stay together; other characters are shown literally.",
            "支持 [logo]、[money]、[money:plain]、[money:0:plain] 到 [money:6:plain]、[money:compact:plain]，以及只输出数字的 [cost] 占位符。相邻的文字和 cost 会保持在一起；其他字符按原样显示。"
        )
    }
    func menuBarFormatError(_ error: MenuBarFormat.ValidationError?) -> String {
        switch error {
        case .empty: return text("The format cannot be empty.", "格式不能为空。")
        case .tooLong: return text("The format is too long.", "格式太长。")
        case .unclosedToken: return text("A placeholder is missing its closing ].", "占位符缺少结束符 ]。")
        case let .unsupportedToken(token): return text("Unsupported placeholder [\(token)].", "不支持的占位符 [\(token)]。")
        case .invalidPrecision: return text("Precision must be an integer from 0 to 6.", "精度必须是 0 到 6 的整数。")
        case .missingToken: return text("Add at least one placeholder.", "至少添加一个占位符。")
        case .controlCharacter: return text("Control characters are not allowed.", "不支持控制字符。")
        case nil: return text("The format is invalid.", "格式无效。")
        }
    }
    var save: String { text("Save", "保存") }
    var automaticPricing: String { text("Automatic pricing", "自动更新价格") }
    var quitApp: String { text("Quit Meterlark", "退出 Meterlark") }
    var metric: String { text("Metric", "指标") }
    var breakdown: String { text("Breakdown", "分组") }
    var byAgent: String { text("by Agent", "按 Agent") }
    var byModel: String { text("by Model", "按模型") }
    var hoverForDetails: String { text("Hover a date to inspect its details", "将鼠标移到日期上查看明细") }
    var clickToPin: String { text("Hover a date · click to pin", "悬停日期 · 点击固定") }
    var clickToPinShort: String { text("Click to pin", "点击固定") }
    var pinned: String { text("Pinned", "已固定") }
    var unpin: String { text("Unpin details", "取消固定明细") }
    var total: String { text("Total", "总计") }
    var totalCost: String { text("Total cost", "总费用") }
    var peak: String { text("Peak", "峰值") }
    var peakDay: String { text("Peak day", "峰值日") }
    var stale: String { text("stale", "已过期") }
}
