import Foundation
protocol C: Sendable { func ingest() async -> Bool }
final class F: C, @unchecked Sendable {
    func ingest() async -> Bool { Thread.isMainThread }
}
@main struct M { static func main() async {
    let f: any C = F()
    print("ingest on main:", await f.ingest())
} }
