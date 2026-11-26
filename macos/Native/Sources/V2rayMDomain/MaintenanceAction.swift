package enum MaintenanceAction: Equatable {
    case subscriptions, saveState, cleanFiles, geo

    package static func due(minute: Int, geoHours: Int) -> [Self] {
        guard minute > 0 else { return [] }
        var actions: [Self] = [.subscriptions]
        if minute.isMultiple(of: 20) { actions.append(.saveState) }
        if minute.isMultiple(of: 60) {
            actions.append(.cleanFiles)
            if geoHours > 0, (minute / 60).isMultiple(of: geoHours) { actions.append(.geo) }
        }
        return actions
    }
}
