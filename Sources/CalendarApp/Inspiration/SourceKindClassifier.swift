import Foundation
import WorkspaceDomain

enum SourceKindClassifier {
    static func classify(_ url: URL) -> ResolvedSourceKind? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        if host == "b23.tv" { return .video }
        if (host == "bilibili.com" || host.hasSuffix(".bilibili.com")),
           path.hasPrefix("/video/") { return .video }
        if (host == "xiaoyuzhoufm.com" || host.hasSuffix(".xiaoyuzhoufm.com")),
           path.hasPrefix("/episode/") { return .audio }
        return nil
    }
}
