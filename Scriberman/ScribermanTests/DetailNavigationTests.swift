import Foundation
import Testing
@testable import Scriberman

/// What the detail column shows for the selected session: the session itself, or a transformation
/// pushed on top of it.
struct DetailNavigationTests {
    @Test
    func startsOnTheSession() {
        let navigation = DetailNavigation()

        #expect(navigation.path.isEmpty)
        #expect(navigation.searchSeed == nil)
    }

    @Test
    func openingATransformationPushesIt() {
        var navigation = DetailNavigation()
        let transformationID = UUID()

        navigation.openTransformation(transformationID)

        #expect(navigation.path == [.transformation(transformationID)])
    }

    @Test
    func backPopsTheTransformation() {
        var navigation = DetailNavigation()
        navigation.openTransformation(UUID())

        navigation.back()

        #expect(navigation.path.isEmpty)
    }

    @Test
    func backOnTheSessionChangesNothing() {
        var navigation = DetailNavigation()

        navigation.back()

        #expect(navigation.path.isEmpty)
    }

    @Test
    func returningToTheSessionClearsThePath() {
        var navigation = DetailNavigation()
        navigation.openTransformation(UUID())

        navigation.returnToSession()

        #expect(navigation.path.isEmpty)
    }

    @Test
    func selectingAnotherSessionResetsThePath() {
        var navigation = DetailNavigation()
        navigation.openTransformation(UUID())

        navigation.selectionChanged(to: "recording-2")

        #expect(navigation.path.isEmpty)
    }

    @Test
    func selectingAnotherSessionDropsASeedForADifferentSession() {
        var navigation = DetailNavigation()
        navigation.openSearchResult(itemID: "recording-1", seed: TranscriptSearchSeed(query: "migration", blockID: UUID()))

        navigation.selectionChanged(to: "recording-2")

        #expect(navigation.searchSeed == nil)
    }

    @Test
    func clearingTheSelectionDropsTheSeed() {
        var navigation = DetailNavigation()
        navigation.openSearchResult(itemID: "recording-1", seed: TranscriptSearchSeed(query: "migration", blockID: UUID()))

        navigation.selectionChanged(to: nil)

        #expect(navigation.searchSeed == nil)
    }

    @Test
    func openingASearchResultClearsThePathAndHoldsTheSeed() {
        var navigation = DetailNavigation()
        navigation.openTransformation(UUID())
        let seed = TranscriptSearchSeed(query: "migration", blockID: UUID())

        navigation.openSearchResult(itemID: "recording-1", seed: seed)

        #expect(navigation.path.isEmpty)
        #expect(navigation.searchSeed == seed)
    }

    /// The result's selection change arrives after the seed is set; it must not undo it.
    @Test
    func theSelectionChangeOfASearchResultKeepsItsSeed() {
        var navigation = DetailNavigation()
        let seed = TranscriptSearchSeed(query: "migration", blockID: UUID())

        navigation.openSearchResult(itemID: "recording-1", seed: seed)
        navigation.selectionChanged(to: "recording-1")

        #expect(navigation.path.isEmpty)
        #expect(navigation.searchSeed == seed)
    }

    /// A title-only result has no match: the session opens with nothing selected.
    @Test
    func aTitleOnlyResultOpensWithoutASeed() {
        var navigation = DetailNavigation()
        navigation.openSearchResult(itemID: "recording-1", seed: TranscriptSearchSeed(query: "migration", blockID: UUID()))

        navigation.openSearchResult(itemID: "recording-2", seed: nil)
        navigation.selectionChanged(to: "recording-2")

        #expect(navigation.path.isEmpty)
        #expect(navigation.searchSeed == nil)
    }

    /// Clicking the same result again changes no selection, so the new seed alone moves the view.
    @Test
    func openingTheSameResultAgainGivesANewSeed() {
        var navigation = DetailNavigation()
        let blockID = UUID()
        navigation.openSearchResult(itemID: "recording-1", seed: TranscriptSearchSeed(query: "migration", blockID: blockID))
        let first = navigation.searchSeed

        navigation.openSearchResult(itemID: "recording-1", seed: TranscriptSearchSeed(query: "migration", blockID: blockID))

        #expect(navigation.searchSeed != first)
    }

    @Test
    func theSessionShowsOnlyWithAnEmptyPath() {
        var navigation = DetailNavigation()
        #expect(navigation.isSessionShown)

        navigation.openTransformation(UUID())
        #expect(!navigation.isSessionShown)
    }
}
