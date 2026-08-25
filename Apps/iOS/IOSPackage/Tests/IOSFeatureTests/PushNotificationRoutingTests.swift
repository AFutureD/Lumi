import Transport
import Foundation
import Testing
@testable import IOSFeature

@Test func pushPayloadNamesItsSession() {
    let userInfo: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "t", "body": "b"]],
        "lumi": ["hostID": "host-abc", "sessionID": "01J9EX7M4T2QZR8B3H0V5CKD9A"],
    ]
    let target = PushNotificationRouting.session(in: userInfo)
    #expect(target?.hostID == HostID("host-abc"))
    #expect(target?.sessionID == SessionID("01J9EX7M4T2QZR8B3H0V5CKD9A"))
}

@Test func malformedPushPayloadsResolveToNothing() {
    #expect(PushNotificationRouting.session(in: [:]) == nil)
    #expect(PushNotificationRouting.session(in: ["lumi": ["hostID": "only-host"]]) == nil)
    #expect(PushNotificationRouting.session(in: ["lumi": ["hostID": 1, "sessionID": 2]]) == nil)
    #expect(PushNotificationRouting.session(in: ["lumi": "not-a-dictionary"]) == nil)
}
