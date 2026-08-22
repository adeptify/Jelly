import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("SourceKindClassifierTests")
struct SourceKindClassifierTests {
    @Test func classifiesOnlySupportedMaterialPages() {
        let cases: [(String, ResolvedSourceKind?)] = [
            ("https://www.bilibili.com/video/BV1xx411c7mD/", .video),
            ("https://m.bilibili.com/video/av170001", .video),
            ("https://b23.tv/jKx2Ab", .video),
            ("https://www.bilibili.com/read/cv123", nil),
            ("https://space.bilibili.com/123", nil),
            ("https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e", .audio),
            ("https://www.xiaoyuzhoufm.com/podcast/5e2c8f0be1b3f16a04cb0f2e", nil),
            ("https://notbilibili.com/video/BV1", nil),
            ("https://fakexiaoyuzhoufm.com/episode/1", nil),
            ("https://example.com/post", nil)
        ]
        for (raw, expected) in cases {
            #expect(SourceKindClassifier.classify(URL(string: raw)!) == expected)
        }
    }
}
