/* ScummVM - Graphic Adventure Engine
 *
 * ScummVM is the legal property of its developers, whose names
 * are too numerous to list here. Please refer to the COPYRIGHT
 * file distributed with this source distribution.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

// Disable symbol overrides so that we can use system headers.
#define FORBIDDEN_SYMBOL_ALLOW_ALL

// Needs to be included first as system headers redefine NO and YES, which clashes
// with the DisposeAfterUse::Flag enum used in Common stream classes.
#include "common/file.h"

#include "backends/platform/ios7/ios7_osys_main.h"
#include "base/version.h"

#include <Foundation/NSBundle.h>
#include <Foundation/NSFileManager.h>
#include <Foundation/NSUserDefaults.h>
#include <UIKit/UIKit.h>
#include <SystemConfiguration/SCNetworkReachability.h>
#include "backends/platform/ios7/ios7_app_delegate.h"
#include "backends/platform/ios7/ios7_video.h"

static inline void execute_on_main_thread_async(void (^block)(void)) {
	if ([NSThread currentThread] == [NSThread mainThread]) {
		block();
	} else {
		dispatch_async(dispatch_get_main_queue(), block);
	}
}

void OSystem_iOS7::updateStartSettings(const Common::String &executable, Common::String &command, Common::StringMap &settings, Common::StringArray& additionalArgs) {
		NSBundle* bundle = [NSBundle mainBundle];
		// Check if scummvm is running from an app bundle
		if (!bundle || ![bundle bundleIdentifier]) {
			// Use default autostart implementation
			EventsBaseBackend::updateStartSettings(executable, command, settings, additionalArgs);
			return;
		}

		// If the bundle contains a scummvm.ini, use it as initial config
		NSString *iniPath = [bundle pathForResource:@"scummvm" ofType:@"ini"];
		if (iniPath && !settings.contains("initial-cfg")) {
#ifdef IPHONE_SANDBOXED
			settings["initial-cfg"] = "appbundle:/scummvm.ini";
#else
			settings["initial-cfg"] = Common::String([iniPath fileSystemRepresentation]);
#endif
		}

		// If a command was specified on the command line, do not override it
		if (!command.empty())
			return;

		// Check if we have an autorun file with additional arguments
		NSString *autorunPath = [bundle pathForResource:@"scummvm-autorun" ofType:nil];
		if (autorunPath) {
			Common::File autorun;
			Common::String line;
#ifdef IPHONE_SANDBOXED
			if (autorun.open(Common::FSNode("appbundle:/scummvm-autorun"))) {
#else
			if (autorun.open(Common::FSNode([autorunPath fileSystemRepresentation]))) {
#endif
				while (!autorun.eos()) {
					line = autorun.readLine();
					if (!line.empty() && line[0] != '#')
						additionalArgs.push_back(line);
				}
			}
			autorun.close();
		}

		// If the bundle contains a game directory, auto-detect it
		NSString *gamePath = [[bundle resourcePath] stringByAppendingPathComponent:@"game"];
		BOOL isDir = false;
		BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:gamePath isDirectory:&isDir];
		if (exists && isDir) {
			// Use auto-detection
			command = "auto-detect";
#ifdef IPHONE_SANDBOXED
			settings["path"] = "appbundle:/game";
#else
			settings["path"] = [gamePath fileSystemRepresentation];
#endif
			return;
		}

		// The rest of the function has some commands executed only the first time after each version change
		// Check the last version stored in the user settings.
		NSString *versionString = [NSString stringWithUTF8String:gScummVMFullVersion];
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		NSString *lastVersion = [defaults stringForKey:@"lastVersion"];
		if (lastVersion && [lastVersion isEqualToString:versionString])
			return;
		[defaults setObject:versionString forKey:@"lastVersion"];

		// If the bundle contains a games directory, add them to the launcher
		NSString *gamesPath = [[bundle resourcePath] stringByAppendingPathComponent:@"games"];
		isDir = false;
		exists = [[NSFileManager defaultManager] fileExistsAtPath:gamesPath isDirectory:&isDir];
		if (exists && isDir) {
			// Detect and add games
			command = "add";
#ifdef IPHONE_SANDBOXED
			settings["path"] = "appbundle:/games";
#else
			settings["path"] = [gamesPath fileSystemRepresentation];
#endif
			settings["recursive"] = "true";
			settings["exit"] = "false";
			return;
		}

}

Common::String OSystem_iOS7::getSystemLanguage() const {
	NSString *language = [[NSLocale preferredLanguages] firstObject];
	if (language == nil)
		return Common::String();
	Common::String lang([language cStringUsingEncoding:NSISOLatin1StringEncoding]);
	// Depending on the iOS version this may use an underscore (e.g. en_US) or a
	// dash (en-US). Make sure we always return one with an underscore.
	Common::replace(lang, "-", "_");
	return lang;
}

bool OSystem_iOS7::hasTextInClipboard() {
#if TARGET_OS_IOS
	return [[UIPasteboard generalPasteboard] containsPasteboardTypes:UIPasteboardTypeListString];
#else
	return false;
#endif
}

Common::U32String OSystem_iOS7::getTextFromClipboard() {
	if (!hasTextInClipboard())
		return Common::U32String();

#if TARGET_OS_IOS
	UIPasteboard *pb = [UIPasteboard generalPasteboard];
	NSString *str = pb.string;
	if (str == nil)
		return Common::U32String();

	// If translations are supported, use the current TranslationManager charset and otherwise
	// use ASCII. If the string cannot be represented using the requested encoding we get a null
	// pointer below, which is fine as ScummVM would not know what to do with the string anyway.
#ifdef SCUMM_LITTLE_ENDIAN
	NSStringEncoding stringEncoding = NSUTF32LittleEndianStringEncoding;
#else
	NSStringEncoding stringEncoding = NSUTF32BigEndianStringEncoding;
#endif
	NSUInteger textLength = [str length];
	uint32 *text = new uint32[textLength];

	if (![str getBytes:text maxLength:4*textLength usedLength:NULL encoding: stringEncoding options:0 range:NSMakeRange(0, textLength) remainingRange:NULL]) {
		delete[] text;
		return Common::U32String();
	}

	Common::U32String u32String(text, textLength);
	delete[] text;

	return u32String;
#else
	return Common::U32String();
#endif
}

bool OSystem_iOS7::setTextInClipboard(const Common::U32String &text) {
#if TARGET_OS_IOS
#ifdef SCUMM_LITTLE_ENDIAN
	NSStringEncoding stringEncoding = NSUTF32LittleEndianStringEncoding;
#else
	NSStringEncoding stringEncoding = NSUTF32BigEndianStringEncoding;
#endif
	UIPasteboard *pb = [UIPasteboard generalPasteboard];
	NSString *nsstring = [[NSString alloc] initWithBytes:text.c_str() length:4*text.size() encoding: stringEncoding];
	[pb setString:nsstring];
	[nsstring release];
	return true;
#else
	return false;
#endif
}

bool OSystem_iOS7::openUrl(const Common::String &url) {
	UIApplication *application = [UIApplication sharedApplication];
	NSURL *nsurl = [NSURL URLWithString:[NSString stringWithCString:url.c_str() encoding:NSISOLatin1StringEncoding]];
	// The way to oipen a URL has changed in iOS 10. Check if the iOS 10 method is recognized
	// and otherwise use the old method.
	if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
		execute_on_main_thread_async(^ {
			[application openURL:nsurl options:@{} completionHandler:nil];
		});
	} else {
		execute_on_main_thread_async(^ {
			[application openURL:nsurl];
		});
	}
	return true;
}

bool OSystem_iOS7::isConnectionLimited() {
	// If we are connected to the internet through a cellular network, return true
	SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithName(CFAllocatorGetDefault(), [@"www.google.com" UTF8String]);
	if (!ref)
		return false;
	SCNetworkReachabilityFlags flags = 0;
	SCNetworkReachabilityGetFlags(ref, &flags);
	CFRelease(ref);
	return (flags & kSCNetworkReachabilityFlagsIsWWAN);
}

Common::HardwareInputSet *OSystem_iOS7::getHardwareInputSet() {
	using namespace Common;

	CompositeHardwareInputSet *inputSet = new CompositeHardwareInputSet();
	// Ask view about connected controllers
	if ([[iOS7AppDelegate iPhoneView] isTouchControllerConnected] ||
		[[iOS7AppDelegate iPhoneView] isMouseControllerConnected]) {
		inputSet->addHardwareInputSet(new MouseHardwareInputSet(defaultMouseButtons));
	}

	if ([[iOS7AppDelegate iPhoneView] isGamepadControllerConnected]) {
		inputSet->addHardwareInputSet(new JoystickHardwareInputSet(defaultJoystickButtons, defaultJoystickAxes));
	}

	return inputSet;
}

void OSystem_iOS7::handleEvent_applicationSaveState() {
	[[iOS7AppDelegate iPhoneView] beginBackgroundSaveStateTask];
	saveState();
	[[iOS7AppDelegate iPhoneView] endBackgroundSaveStateTask];
}

void OSystem_iOS7::handleEvent_applicationRestoreState() {
	restoreState();
}

void OSystem_iOS7::handleEvent_applicationClearState() {
	clearState();
}
