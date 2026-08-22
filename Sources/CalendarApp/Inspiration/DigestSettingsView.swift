import SwiftUI

struct DigestSettingsView: View {
    var settings: DigestSettingsStore
    let credentials: any DigestCredentialStoring
    @State private var endpointDraft = ""
    @State private var modelDraft = ""
    @State private var apiKeyDraft = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("材料提炼") {
                TextField("HTTPS 接口地址", text: $endpointDraft)
                    .textContentType(.URL)
                TextField("模型名称", text: $modelDraft)
                SecureField("API 密钥", text: $apiKeyDraft)
                HStack {
                    Button("保存") { save() }
                    Button("删除密钥", role: .destructive) { deleteKey() }
                }
                if !status.isEmpty {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 280)
        .onAppear {
            endpointDraft = settings.endpoint
            modelDraft = settings.model
            apiKeyDraft = ""
        }
    }

    private func save() {
        guard settings.save(endpoint: endpointDraft, model: modelDraft) else {
            status = "请填写 HTTPS 接口地址和非空模型名称。"
            return
        }
        do {
            if apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = "已保存接口和模型；密钥未改动。"
            } else {
                try credentials.save(apiKeyDraft)
                apiKeyDraft = ""
                status = "已保存材料提炼设置。"
            }
        } catch {
            status = "密钥未能写入钥匙串。"
        }
    }

    private func deleteKey() {
        do {
            try credentials.delete()
            apiKeyDraft = ""
            status = "已删除密钥。摘要设置仍保留在本机。"
        } catch {
            status = "删除密钥失败。"
        }
    }
}
