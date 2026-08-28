                    model.subscriptions[topic.name] = .failed(error.localizedDescription)
                    continue
                }
            }

            guard case .loaded(let subs) = model.subscriptions[topic.name] else { continue }
            for sub in subs {
                let key = "\(sub.topicName)/\(sub.name)"
                model.expandedSubscriptions.insert(key)
                model.expandedRuleGroups.insert(key)

                if model.rules[key] == nil {
                    model.rules[key] = .loading
                    do {
                        let ruleInfos = try await grpc.listRules(topicName: sub.topicName,
                                                                  subscriptionName: sub.name)
                        model.rules[key] = .loaded(ruleInfos.map {
                            RuleItem(name: $0.name, filter: $0.filter)
                        })
                    } catch {
                        model.rules[key] = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func collapseAllTopics() {
        topicsExpanded = false
        model.expandedTopics = []
        model.expandedSubscriptions = []
        model.expandedRuleGroups = []
    }
}

// MARK: - TopicRow

@available(macOS 15.0, *)
private struct TopicRow: View {
    let topic: TopicItem
    let model: SidebarModel
    let grpc: GRPCManager

    @Environment(ActivityLogStore.self) var activityLog

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { model.expandedTopics.contains(topic.name) },
            set: { expanded in
                if expanded { model.expandedTopics.insert(topic.name) }
                else { model.expandedTopics.remove(topic.name) }
            }
        )
    }

    private var isExpanded: Bool { model.expandedTopics.contains(topic.name) }

    var body: some View {
        DisclosureGroup(isExpanded: isExpandedBinding) {
            switch model.subscriptions[topic.name] {
            case .none, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading subscriptions…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 8)

            case .failed(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                    Button("Retry") { Task { await loadSubscriptions() } }
                        .font(.caption)
                }
                .padding(.leading, 8)

            case .loaded(let subs):
                if subs.isEmpty {
                    Text("No subscriptions").font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                } else {
                    ForEach(subs) { sub in
                        SubscriptionRow(sub: sub, model: model, grpc: grpc)
                            .padding(.leading, 8)
                    }
                }
            }
        } label: {
            HStack {
                Label(topic.name, systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(topic.status == "Disabled" ? .secondary : .primary)
                if topic.status == "Disabled" {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .tag(SidebarSelection.topic(topic))
            .id(SidebarSelection.topic(topic))
            .contextMenu {
                    Button("Send Message") {
                        model.sendMessageTarget  = .topic(topic)
                        model.showSendMessageSheet = true
                    }
                    .disabled(!grpc.capabilityMap.purge)
                    Divider()
                    Button("Create Subscription") {
                        model.createSubscriptionTopic = topic
                        model.showCreateSubscriptionSheet = true
                    }
                    .disabled(!grpc.capabilityMap.createResources)
                    Divider()
                    if topic.status == "Disabled" {
                        Button("Enable Topic") {
                            model.disableTopicTarget = topic
                            Task { await performEnableTopic() }
                        }
                        .disabled(!grpc.capabilityMap.createResources)
                    } else {
