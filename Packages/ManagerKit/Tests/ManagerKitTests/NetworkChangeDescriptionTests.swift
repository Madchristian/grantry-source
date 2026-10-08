import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkChangeDescriptionTests {
    private func event(_ kind: ChangeEvent.Kind, before: NetworkListener? = nil, after: NetworkListener? = nil) -> ChangeEvent {
        ChangeEvent(kind: kind, before: before.map(ChangeSubject.networkListener),
                    after: after.map(ChangeSubject.networkListener), detectedAt: TestData.date)
    }

    @Test func added() {
        let description = ChangeDescription(event(.added, after: TestData.listener()))
        #expect(description == ChangeDescription(title: "Neuer Netzwerkdienst",
                                                 body: "node lauscht auf Port 3000/tcp (alle Schnittstellen)."))
        let variable = ChangeDescription(event(.added, after: TestData.listener(port: nil, addresses: ["127.0.0.1"])))
        #expect(variable.body == "node lauscht auf einem wechselnden Port (tcp, nur dieser Mac).")
        let lan = ChangeDescription(event(.added, after: TestData.listener(addresses: ["192.168.1.5"])))
        #expect(lan.body == "node lauscht auf Port 3000/tcp (Netzwerk, 192.168.1.5).")
    }

    @Test func exposureChange() {
        let local = TestData.listener(addresses: ["127.0.0.1"])
        let exposed = TestData.listener(addresses: ["0.0.0.0"])
        #expect(ChangeDescription(event(.modified, before: local, after: exposed))
            == ChangeDescription(title: "Netzwerkdienst jetzt von außen erreichbar",
                                 body: "node, Port 3000/tcp: nur dieser Mac → alle Schnittstellen."))
        #expect(ChangeDescription(event(.modified, before: exposed, after: local)).title
            == "Netzwerkdienst nur noch lokal erreichbar")
        let lan = TestData.listener(addresses: ["192.168.1.5"])
        #expect(ChangeDescription(event(.modified, before: lan, after: exposed))
            == ChangeDescription(title: "Netzwerkdienst: Erreichbarkeit geändert",
                                 body: "node, Port 3000/tcp: Netzwerk, 192.168.1.5 → alle Schnittstellen."))
    }

    @Test func removed() {
        #expect(ChangeDescription(event(.removed, before: TestData.listener()))
            == ChangeDescription(title: "Netzwerkdienst beendet", body: "node, Port 3000/tcp."))
        #expect(ChangeDescription(event(.removed, before: TestData.listener(port: nil))).body
            == "node, wechselnder Port, tcp.")
    }

    @Test func userNames() {
        #expect(ListenerUser.current.displayName == "Eigener Benutzer")
        #expect(ListenerUser.root.displayName == "System (root)")
        #expect(ListenerUser.other(uid: 502).displayName == "Anderer Benutzer (502)")
    }
}
