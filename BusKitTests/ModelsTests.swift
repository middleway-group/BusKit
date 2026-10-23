import XCTest
@testable import BusKit

final class ModelsTests: XCTestCase {
    // MARK: ConnectionState

    func testConnectionStateDisplayAndColor() {
        XCTAssertEqual(ConnectionState.disconnected.displayName, "Disconnected")
        XCTAssertEqual(ConnectionState.connected.color, "green")
        XCTAssertEqual(ConnectionState.error("boom").displayName, "Error: boom")
        XCTAssertEqual(ConnectionState.error("boom").color, "red")
        XCTAssertNotEqual(ConnectionState.error("a"), ConnectionState.error("b"))
    }

    // MARK: AccessTier

    func testAccessTierIsOrdered() {
        XCTAssertEqual(AccessTier.allCases.sorted(), AccessTier.allCases)
        XCTAssertLessThan(AccessTier.readOnly, .messageReader)
        XCTAssertLessThan(AccessTier.messageOperator, .fullAccess)
    }

    func testAccessTierMapsFromGrpcTier() {
        XCTAssertEqual(AccessTier(from: .fullAccess), .fullAccess)
        XCTAssertEqual(AccessTier(from: .messageOperator), .messageOperator)
        XCTAssertEqual(AccessTier(from: .noAccess), .noAccess)
    }

    func testUnknownGrpcTierFallsBackToNoAccess() {
        XCTAssertEqual(AccessTier(from: .UNRECOGNIZED(99)), .noAccess)
    }

    func testEveryTierHasPresentationValues() {
        for tier in AccessTier.allCases {
            XCTAssertFalse(tier.displayName.isEmpty)
            XCTAssertFalse(tier.shortDescription.isEmpty)
            XCTAssertFalse(tier.badgeColor.isEmpty)
            XCTAssertFalse(tier.badgeSystemImage.isEmpty)
        }
    }

    // MARK: CapabilityMap

    func testCapabilityMapNoneAndAll() {
        for capability in CapabilityMap.Capability.allCases {
            XCTAssertFalse(CapabilityMap.none[capability])
            XCTAssertTrue(CapabilityMap.all[capability])
        }
    }

    func testCapabilityMapFromReply() {
        var reply = Buskit_CheckRbacPermissionsReply()
        reply.canBrowseEntities = true
        reply.canPeekFetch = true
        reply.canPurge = true

        let map = CapabilityMap(from: reply)

        XCTAssertTrue(map[.browseEntities])
        XCTAssertTrue(map[.peekFetch])
        XCTAssertTrue(map[.purge])
        XCTAssertFalse(map[.viewProperties])
        XCTAssertFalse(map[.resubmitDlq])
        XCTAssertFalse(map[.createResources])
        XCTAssertFalse(map[.manageFilters])
    }

    func testDisabledReasonOnlyWhenCapabilityMissing() {
        XCTAssertNil(CapabilityMap.all.disabledReason(for: .purge))
        XCTAssertEqual(CapabilityMap.none.disabledReason(for: .createResources),
                       CapabilityMap.Capability.createResources.requiredPermission)
    }

    func testEveryCapabilityHasDisplayNameAndPermission() {
        for capability in CapabilityMap.Capability.allCases {
            XCTAssertFalse(capability.displayName.isEmpty)
            XCTAssertTrue(capability.requiredPermission.hasPrefix("Requires:"))
        }
    }

    // MARK: UpgradeRecommendation

    func testUpgradeRecommendationIsNilWithoutRoleName() {
        XCTAssertNil(UpgradeRecommendation(from: Buskit_CheckRbacPermissionsReply()))
    }

    func testUpgradeRecommendationMapsFields() {
        var reply = Buskit_CheckRbacPermissionsReply()
        reply.recommendedRoleName = "Azure Service Bus Data Owner"
        reply.recommendedRoleID = "role-id"
        reply.recommendedRoleDescription = "desc"
        reply.recommendedTargetTier = .fullAccess

        let rec = UpgradeRecommendation(from: reply)

        XCTAssertEqual(rec?.roleName, "Azure Service Bus Data Owner")
        XCTAssertEqual(rec?.roleDefinitionId, "role-id")
        XCTAssertEqual(rec?.description, "desc")
        XCTAssertEqual(rec?.targetTier, .fullAccess)
    }

    // MARK: RbacAccessLevel

    func testRbacAccessLevelDataAndManagementAccess() {
        let cases: [(RbacAccessLevel, data: Bool, management: Bool)] = [
            (.notApplicable, true, true),
            (.full, true, true),
            (.dataOnly, true, false),
            (.managementOnly, false, true),
            (.denied, false, false),
            (.checking, false, false),
            (.checkFailed("x"), false, false),
        ]
        for (level, data, management) in cases {
            XCTAssertEqual(level.hasDataAccess, data, "\(level) data")
            XCTAssertEqual(level.hasManagementAccess, management, "\(level) management")
        }
    }

    // MARK: Identity

    func testItemsGetDistinctIdsButCompareByIdentity() {
        let a = QueueItem(name: "q", messageCount: 1, deadLetterCount: 0, status: "Active")
        let b = QueueItem(name: "q", messageCount: 1, deadLetterCount: 0, status: "Active")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a)
    }
}
