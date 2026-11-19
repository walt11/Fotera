import XCTest
final class MacUITests: XCTestCase {
    func testDemoLibraryNavigationAndViewer() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout:3) {
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuBarItems["Window"].menus.menuItems["Fotera"].firstMatch.click()
        }
        XCTAssertTrue(app.staticTexts["October 2026"].waitForExistence(timeout:15))
        let library = XCTAttachment(screenshot:app.screenshot()); library.name = "Fotera Mac Library"; library.lifetime = .keepAlways; add(library)
        let photo = app.descendants(matching:.any)["photo.1"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout:5)); photo.doubleClick()
        XCTAssertTrue(app.staticTexts["DEMO_0001.jpg"].waitForExistence(timeout:5))
        let viewer = XCTAttachment(screenshot:app.screenshot()); viewer.name = "Fotera Mac Viewer"; viewer.lifetime = .keepAlways; add(viewer)
        app.buttons["Share…"].firstMatch.click()
        sleep(2)
        let sharing = XCTAttachment(screenshot:app.screenshot()); sharing.name = "Fotera Mac Share Picker"; sharing.lifetime = .keepAlways; add(sharing)
        app.typeKey(.escape,modifierFlags:[])
        app.typeKey(.escape,modifierFlags:[])
        app.descendants(matching:.any)["sidebar.backups"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Photo imports"].waitForExistence(timeout:5))
        app.descendants(matching:.any)["sidebar.folders"].firstMatch.click()
        let folder = app.buttons["folder.9000"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["No photos"].exists)
        XCTAssertLessThan(app.buttons["folder.1993"].frame.minY - app.windows.firstMatch.frame.minY,180)
        let folders = XCTAttachment(screenshot:app.screenshot()); folders.name = "Fotera Mac Folders"; folders.lifetime = .keepAlways; add(folders)
        folder.click()
        XCTAssertFalse(app.buttons["View Photos"].exists)
        let folderPhoto = app.descendants(matching:.any)["photo.1"].firstMatch
        XCTAssertTrue(folderPhoto.waitForExistence(timeout:5)); folderPhoto.doubleClick()
        XCTAssertTrue(app.staticTexts["DEMO_0001.jpg"].waitForExistence(timeout:5))
        app.typeKey(.escape,modifierFlags:[])
        app.buttons["folder.back"].click()
        XCTAssertTrue(folder.waitForExistence(timeout:5))
        app.descendants(matching:.any)["sidebar.albums"].firstMatch.click()
        app.buttons["New Album…"].firstMatch.click()
        let albumName = app.textFields["album.name"]
        XCTAssertTrue(albumName.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["album.create"].isEnabled)
        albumName.click(); albumName.typeText("UI Test Album")
        app.buttons["album.create"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "UI Test Album,")).firstMatch.waitForExistence(timeout:5))
        XCTAssertFalse(albumName.exists)
        app.terminate()
    }
}

extension MacUITests {
    func testNASAlbumContractReadOnly() {
        guard ProcessInfo.processInfo.environment["FOTERA_LIVE_ALBUM_AUDIT"] == "1" else {return}
        let app = XCUIApplication(); app.launchArguments = ["--album-contract-audit"]; if ProcessInfo.processInfo.environment["FOTERA_LIVE_ALBUM_CREATE"] == "1" {app.launchArguments.append("--album-create-audit"); if ProcessInfo.processInfo.environment["FOTERA_LIVE_SHARING_AUDIT"] == "1" {app.launchArguments.append("--album-sharing-audit")}}; app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout:3) {app.menuBars.menuBarItems["Window"].click(); app.menuBars.menuBarItems["Window"].menus.menuItems["Fotera"].firstMatch.click()}
        let report = app.staticTexts["album.audit"]
        XCTAssertTrue(report.waitForExistence(timeout:90))
        let result = report.value as? String ?? report.label
        print(result)
        XCTAssertTrue(result.contains("PASS") || result.contains("album decoding passed"),result)
        app.terminate()
    }
}
