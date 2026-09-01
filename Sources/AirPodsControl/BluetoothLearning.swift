import Foundation

enum BluetoothLearning {
  static let learningWindow: TimeInterval = 24 * 60 * 60

  static func learn(
    document inputDocument: BluetoothSettingsDocument,
    targets: [BluetoothCorrelationTarget],
    observations: [BluetoothPeripheralObservation],
    conflictingProductIDs: Set<Int>,
    now: Date
  ) -> BluetoothSettingsDocument {
    var document = inputDocument
    document.candidates.removeAll { $0.expiresAt <= now }
    guard document.enabled else { return document }

    let establishedPeripheralIDs = Set(
      document.associations.map(\.peripheralIdentifier)
    )

    for productID in Set(targets.map(\.productID)) {
      let bucketTargets = targets.filter { $0.productID == productID }
      let bucketObservations = observations.filter {
        $0.productID == productID
          && !establishedPeripheralIDs.contains($0.peripheralIdentifier)
      }
      if bucketObservations.count > 1 || conflictingProductIDs.contains(productID) {
        document.candidates.removeAll { $0.productID == productID }
        continue
      }
      if bucketTargets.count == 1, let target = bucketTargets.first {
        let evidenceConflicts: Bool
        switch target.placement {
        case let .value(halPlacement):
          evidenceConflicts = bucketObservations.count == 1
            && bucketObservations[0].placement != halPlacement
        case .unresolved, .readError:
          evidenceConflicts = true
        case .unsupported:
          evidenceConflicts = false
        }
        if evidenceConflicts {
          document.candidates.removeAll {
            $0.productID == productID
              && BluetoothSettingsDocument.namesMatch(
                $0.displayName,
                target.name
              )
          }
          continue
        }
      }
      guard bucketTargets.count == 1,
            bucketObservations.count == 1,
            let target = bucketTargets.first,
            let observation = bucketObservations.first,
            !document.hasAssociation(for: target),
            case let .value(halPlacement) = target.placement,
            halPlacement == observation.placement
      else {
        continue
      }

      let state = stateBit(for: observation.placement)
      let candidateIndex = document.candidates.firstIndex {
        $0.productID == target.productID
          && BluetoothSettingsDocument.namesMatch($0.displayName, target.name)
      }
      if let candidateIndex,
         document.candidates[candidateIndex].peripheralIdentifier
          == observation.peripheralIdentifier,
         document.candidates[candidateIndex].coreAudioUIDDigests
          == target.coreAudioUIDDigests
      {
        document.candidates[candidateIndex].observedStates |= state
      } else {
        if let candidateIndex { document.candidates.remove(at: candidateIndex) }
        document.candidates.append(
          BluetoothAssociationCandidate(
            peripheralIdentifier: observation.peripheralIdentifier,
            coreAudioUIDDigests: target.coreAudioUIDDigests,
            productID: productID,
            displayName: target.name,
            observedStates: state,
            expiresAt: now.addingTimeInterval(learningWindow)
          )
        )
      }

      guard let promotedIndex = document.candidates.firstIndex(where: {
        $0.productID == productID
          && BluetoothSettingsDocument.namesMatch($0.displayName, target.name)
      }) else {
        continue
      }
      let candidate = document.candidates[promotedIndex]
      let hasTwoStates = candidate.observedStates.nonzeroBitCount >= 2
      let hasAsymmetricState = candidate.observedStates & 0b0110 != 0
      if hasTwoStates, hasAsymmetricState {
        document.associations.append(
          BluetoothAssociation(
            associationID: UUID(),
            peripheralIdentifier: candidate.peripheralIdentifier,
            coreAudioUIDDigests: candidate.coreAudioUIDDigests,
            productID: candidate.productID,
            displayName: candidate.displayName,
            provenance: .automatic
          )
        )
        document.candidates.remove(at: promotedIndex)
      }
    }

    return document
  }

  static func conflictingProductIDs(
    _ advertisements: [BluetoothAdvertisement]
  ) -> Set<Int> {
    Dictionary(grouping: advertisements, by: \.peripheralIdentifier)
      .reduce(into: Set<Int>()) { result, entry in
        let frames = entry.value.compactMap {
          AirPodsBLEFrameParser.parse(manufacturerData: $0.manufacturerData)
        }
        guard frames.count >= 2, Set(frames).count > 1 else { return }
        result.formUnion(frames.map(\.productID))
      }
  }

  private static func stateBit(for placement: BluetoothEarPlacement) -> UInt8 {
    let left = placement.left == .inEar ? 1 : 0
    let right = placement.right == .inEar ? 1 : 0
    return 1 << UInt8(left * 2 + right)
  }
}
