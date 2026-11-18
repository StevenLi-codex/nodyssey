import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation
final class RecoveryTransport: NativeTransport, @unchecked Sendable {
 let base = ControlledTransport()
 private let lock = NSLock()
 private var observed: [[String: JSONValue]] = []
 func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue { try await base.request(operation, arguments) }
 func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
  lock.lock(); observed.append(arguments); lock.unlock()
  return base.observe(operation, arguments)
 }
 func arguments(for operation: String) -> [[String: JSONValue]] { lock.lock(); defer { lock.unlock() }; return observed }
 func hasStream(_ operation: String) -> Bool { base.hasStream(operation) }
 func emit(_ operation: String, _ value: JSONValue) { base.emit(operation, value) }
}
@Suite @MainActor struct RecoveryTests {
 func snap(_ pager:String,_ page:Int64,_ status:String,_ ids:[Int64],remote:Bool=false)->JSONValue {
 .object(["pagerId":.string(pager),"page":.integer(page),"placeholdersBefore":.integer(0),"placeholdersAfter":.integer(0),"itemCount":.integer(Int64(ids.count)),"refresh":.object(["status":.string(status)]),"remoteRefreshComplete":.bool(remote),"items":.array(ids.map{.object(["summary":.object(["postId":.integer($0)]),"page":.integer(page)])})])
 }
 @Test func failedReplacementGestureRetriesWithRetainedRows() async throws {
  let t=RecoveryTransport();let app=NativeAppModel(transport:t);let s=NativeStore();let f=ContentFeedTopRefreshFlight();let owner=ContentFeedTicket(generation:0,board:"",sort:"",observation:UUID())
  s.observeRetained(app,"feed",["pagerId":.string("old"),"page":.integer(8)])
  try await eventually{t.hasStream("feed")};t.emit("feed",snap("old",8,"NotLoading",[81]));try await eventually{s.hasValue}
  s.observeRetained(app,"feed",["pagerId":.string("failed"),"page":.integer(1)],restart:1)
  for _ in 0..<50{await Task.yield()};t.emit("feed",snap("failed",1,"Loading",[]));try await eventually{s.value["pagerId"]?.string=="failed"}
  t.emit("feed",snap("failed",1,"Error",[]));try await eventually{s.value["refresh"]?["status"]?.string=="Error"}
  #expect(s.isReplacingPagingWindow);#expect(s.value.nativeArray("items").count==1)
  // Exact shipping planner plus the same subsequent Feed admission guard.
  let plan=try ContentFeedTopRefresh.plan(s.value,atTop:true)
  guard case .replace=plan else {#expect(!s.isReplacingPagingWindow,"new explicit gesture is rejected by Feed's replacement guard");s.cancel();return}
  var result:Bool?;let wait=Task{result=await f.wait(owner:owner,pager:"recovery",start:{
   s.observeRetained(app,"feed",["pagerId":.string("recovery"),"page":.integer(1),"forceInitialRefresh":.bool(true)],restart:2)
  })}
  while !f.pending{await Task.yield()};for _ in 0..<50{await Task.yield()}
  #expect(s.value.nativeArray("items").count==1,"one-shot flag must not clear retained rows")
  #expect(!s.observeRetained(app,"feed",["pagerId":.string("echo"),"page":.integer(1)],restart:2),"parent flag-free echo cannot restart pager")
  #expect(t.arguments(for:"feed").count==3)
  t.emit("feed",snap("recovery",1,"NotLoading",[1],remote:false));try await eventually{s.value["pagerId"]?.string=="recovery"};f.update(s.value,current:owner)
  #expect(f.pending && result==nil,"cached NotLoading must await current remote terminal")
  t.emit("feed",snap("recovery",1,"NotLoading",[2],remote:true));try await eventually{s.value.nativeArray("items").first?["summary"]?["postId"]?.int==2};f.update(s.value,current:owner)
  await wait.value;#expect(result==true);#expect(!s.isReplacingPagingWindow);s.cancel()
 }
 @Test func cachedTerminalWithoutRemoteEvidenceCannotComplete() async {
  let f=ContentFeedTopRefreshFlight();let owner=ContentFeedTicket(generation:0,board:"",sort:"",observation:UUID())
  let wait=Task{await f.wait(owner:owner,pager:"new",start:{})};while !f.pending{await Task.yield()}
  f.update(snap("new",1,"NotLoading",[1]),current:owner);#expect(f.pending,"cached NotLoading false cannot report success")
  f.update(snap("new",1,"NotLoading",[2],remote:true),current:owner);#expect(await wait.value)
 }
}
