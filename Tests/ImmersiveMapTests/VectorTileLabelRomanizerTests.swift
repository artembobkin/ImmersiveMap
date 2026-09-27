// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class VectorTileLabelRomanizerTests: XCTestCase {
    private let english = VectorTileLabelRomanizer(targetLanguage: .english)
    private let german = VectorTileLabelRomanizer(targetLanguage: .german)

    /// BGN, folded to ASCII, with the soft and hard signs dropped.
    func testCyrillicIsRomanizedThroughBGNWithoutDiacritics() {
        XCTAssertEqual(english.romanize("Большой театр (Новая сцена)"), "Bolshoy teatr (Novaya stsena)")
        XCTAssertEqual(english.romanize("Воробьёвы горы"), "Vorobyevy gory")
        XCTAssertEqual(english.romanize("Ельцин-центр"), "Yeltsin-tsentr")
    }

    func testEnglishMovesATranslatedStreetTypeToTheEnd() {
        XCTAssertEqual(english.romanize("Георгиевский переулок"), "Georgiyevskiy Lane")
        XCTAssertEqual(english.romanize("улица Щепкина"), "Shchepkina Street")
        XCTAssertEqual(english.romanize("Малая Бронная улица"), "Malaya Bronnaya Street")
        XCTAssertEqual(english.romanize("M10 · Ленинградское шоссе"), "M10 · Leningradskoye Highway")
    }

    /// A capitalized type word is part of a proper name, and a lone one is
    /// the whole name: both stay transliterated.
    func testAStreetTypeThatIsPartOfTheNameStays() {
        XCTAssertEqual(english.romanize("Площадь Революции"), "Ploshchad Revolyutsii")
        XCTAssertEqual(english.romanize("улица"), "ulitsa")
    }

    /// Only English translates the street type: other languages keep the
    /// transliterated word.
    func testOtherLatinLanguagesKeepTheTransliteratedStreetType() {
        XCTAssertEqual(german.romanize("Георгиевский переулок"), "Georgiyevskiy pereulok")
    }

    func testGreekArmenianAndGeorgianAreRomanized() {
        XCTAssertEqual(english.romanize("Αθήνα"), "Athena")
        XCTAssertEqual(english.romanize("Երևան"), "Erevan")
        XCTAssertEqual(english.romanize("თბილისი"), "Tbilisi", "Georgian writes names without a capital, Latin with one")
    }

    /// The generic transliterator reads kanji as Mandarin and drops the
    /// vowels of Arabic: those names are declined, whole.
    func testOtherScriptsAreDeclined() {
        XCTAssertNil(english.romanize("東京駅"))
        XCTAssertNil(english.romanize("القاهرة"))
        XCTAssertNil(english.romanize("Москва 東京"))
    }

    func testALatinNameIsLeftToTheNativeCandidate() {
        XCTAssertNil(english.romanize("Zürich"))
        XCTAssertNil(english.romanize("42"))
    }

    func testAMapInANonLatinLanguageRomanizesNothing() {
        let russian = VectorTileLabelRomanizer(targetLanguage: .russian)
        XCTAssertFalse(russian.isEnabled)
        XCTAssertNil(russian.romanize("Αθήνα"))
    }
}
