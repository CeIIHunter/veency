/* Veency - VNC Remote Access Server for iPhoneOS
 * Copyright (C) 2008-2012  Jay Freeman (saurik)
*/

/* GNU Affero General Public License, Version 3 {{{ */
/*
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.

 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#define _trace() \
    fprintf(stderr, "_trace()@%s:%u[%s]\n", __FILE__, __LINE__, __FUNCTION__)
#define _likely(expr) \
    __builtin_expect(expr, 1)
#define _unlikely(expr) \
    __builtin_expect(expr, 0)

#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)

#include <CydiaSubstrate.h>

#include <rfb/rfb.h>
#include <rfb/keysym.h>

#include <mach/mach_port.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <sys/sysctl.h>

#import <QuartzCore/CAWindowServer.h>
#import <QuartzCore/CAWindowServerDisplay.h>

#import <CoreSurface/CoreSurface.h>
#import <CoreGraphics/CGGeometry.h>
#import <GraphicsServices/GraphicsServices.h>
#import <Foundation/Foundation.h>
#import <IOMobileFramebuffer/IOMobileFramebuffer.h>
#import <IOKit/IOKitLib.h>
#import <UIKit/UIApplication2.h>
#import <UIKit/UIKit.h>
#import <IOKit/hid/IOHIDEvent.h>

#import <SpringBoard/SBAlertItemsController.h>
#import <SpringBoard/SBDismissOnlyAlertItem.h>
#import <SpringBoard/SBStatusBarController.h>

#include "SimulateKeyboard.h"
#include "SpringBoardAccess.h"
#include "SpringBoardAccess.c"
#include "SimulateTouch/SimulateTouch.h"

#define MSHake2(name) \
    (void *)&$ ## name, (void **)&_ ## name


extern "C" void CoreSurfaceBufferFlushProcessorCaches(CoreSurfaceBufferRef buffer);
extern "C" int CoreSurfaceAcceleratorTransferSurface(CoreSurfaceAcceleratorRef accel, CoreSurfaceBufferRef src, CoreSurfaceBufferRef dst, CFDictionaryRef dict);
extern "C" int BKSHIDEventSendToApplicationWithBundleID(IOHIDEventRef event,NSString* str );
static void OnLayer(IOMobileFramebufferRef fb, CoreSurfaceBufferRef layer);

static IOMobileFramebufferRef main_=NULL;
static CoreSurfaceBufferRef layer_=NULL;

static size_t width_;
static size_t height_;
static size_t destwidth_;
static size_t destheight_;
static NSUInteger ratio_ = 0;

static const size_t BytesPerPixel = 4;
static const size_t BitsPerSample = 8;

static CoreSurfaceAcceleratorRef accelerator_;
static CoreSurfaceBufferRef buffer_;
static CFDictionaryRef options_;
static CFDictionaryRef options2_=CFDictionaryCreate(NULL,NULL,NULL,0,NULL,NULL);

static NSMutableSet *handlers_;
static rfbScreenInfoPtr screen_=NULL;
static bool running_;
static int buttons_;
static int x_, y_;

static unsigned clients_;

static CFMessagePortRef ashikase_;
static bool cursor_;
static int skipBlack_;
static int divideScreenBy_=1;

static rfbPixel *black_;
static rfbPixel *mainFrameBuffer_=NULL;
static rfbPixel *correctedBlocksBuffer_=NULL;
static char *bufferData_;

#if 0
// Logging is costly.  Takes 3-6ms
static void Log(const char *str,...) {
FILE *out;
va_list args;


va_start(args,str);
out=fopen("/tmp/veency.log","a");
vfprintf(out,str,args);
fflush(out);
fclose(out);
va_end(args);
}
#endif


static void VNCBlack() {
    if (_unlikely(black_ == NULL))
        black_ = reinterpret_cast<rfbPixel *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));
    screen_->frameBuffer = reinterpret_cast<char *>(black_);
}

static bool Ashikase(bool always) {
    if (!always && !cursor_)
        return false;

    if (ashikase_ == NULL)
        ashikase_ = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("jp.ashikase.mousesupport"));
    if (ashikase_ != NULL)
        return true;

    cursor_ = false;
    return false;
}

static CFDataRef cfTrue_;
static CFDataRef cfFalse_;

typedef struct {
    float x, y;
    int buttons;
    BOOL absolute;
} MouseEvent;

static MouseEvent event_;
static CFDataRef cfEvent_;

typedef enum {
    MouseMessageTypeEvent,
    MouseMessageTypeSetEnabled
} MouseMessageType;

static void AshikaseSendEvent(float x, float y, int buttons = 0) {
    event_.x = x;
    event_.y = y;
    event_.buttons = buttons;
    event_.absolute = true;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeEvent, cfEvent_, 0, 0, NULL, NULL);
}

static void AshikaseSetEnabled(bool enabled, bool always) {
    if (!Ashikase(always))
        return;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeSetEnabled, enabled ? cfTrue_ : cfFalse_, 0, 0, NULL, NULL);

    if (enabled)
        AshikaseSendEvent(x_, y_);
}

MSClassHook(SBAlertItem)
MSClassHook(SBAlertItemsController)
MSClassHook(SBStatusBarController)

//@class VNCAlertItem;
@interface VNCAlertItem : SBAlertItem {

}
@end
static Class $VNCAlertItem;

static NSString *DialogTitle(@"Remote Access Request");
static NSString *DialogFormat(@"Accept connection from\n%s?\n\nVeency VNC Server\nby Jay Freeman (saurik)\nsaurik@saurik.com\nhttp://www.saurik.com/\n\nSet a VNC password in Settings!");
static NSString *DialogAccept(@"Accept");
static NSString *DialogReject(@"Reject");

static volatile rfbNewClientAction action_ = RFB_CLIENT_ON_HOLD;
static NSCondition *condition_;
static NSLock *lock_;

static rfbClientPtr client_;
static int downFinger_=0;

static void VNCSetup();
static void VNCEnabled();
static void VNCShutDown();

static void OnUserNotification(CFUserNotificationRef notification, CFOptionFlags flags) {
    [condition_ lock];

    if ((flags & 0x3) == 1)
        action_ = RFB_CLIENT_ACCEPT;
    else
        action_ = RFB_CLIENT_REFUSE;

    [condition_ signal];
    [condition_ unlock];

    CFRelease(notification);
}

@interface VNCBridge : NSObject {
}

+ (void) askForConnection;
+ (void) removeStatusBarItem;
+ (void) registerClient;

@end

@implementation VNCBridge

+ (void) askForConnection {
    if ($VNCAlertItem != nil) {
        [[$SBAlertItemsController sharedInstance] activateAlertItem:[[[$VNCAlertItem alloc] init] autorelease]];
        return;
    }

    SInt32 error;
    CFUserNotificationRef notification(CFUserNotificationCreate(kCFAllocatorDefault, 0, kCFUserNotificationPlainAlertLevel, &error, (CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
        DialogTitle, kCFUserNotificationAlertHeaderKey,
        [NSString stringWithFormat:DialogFormat, client_->host], kCFUserNotificationAlertMessageKey,
        DialogAccept, kCFUserNotificationAlternateButtonTitleKey,
        DialogReject, kCFUserNotificationDefaultButtonTitleKey,
    nil]));

    if (error != 0) {
        CFRelease(notification);
        notification = NULL;
    }

    if (notification == NULL) {
        [condition_ lock];
        action_ = RFB_CLIENT_REFUSE;
        [condition_ signal];
        [condition_ unlock];
        return;
    }

    CFRunLoopSourceRef source(CFUserNotificationCreateRunLoopSource(kCFAllocatorDefault, notification, &OnUserNotification, 0));
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
}

+ (void) removeStatusBarItem {
    AshikaseSetEnabled(false, false);

    if (SBA_available())
        SBA_removeStatusBarImage(const_cast<char *>("Veency"));
    else if ($SBStatusBarController != nil)
        [[$SBStatusBarController sharedStatusBarController] removeStatusBarItem:@"Veency"];
    else if (UIApplication *app = [UIApplication sharedApplication])
        [app removeStatusBarImageNamed:@"Veency"];
}

+ (void) registerClient {
    // XXX: this could find a better home
    if (ratio_ == 0) {
        UIScreen *screen([UIScreen mainScreen]);
        if ([screen respondsToSelector:@selector(scale)])
            ratio_ = [screen scale];
        else
            ratio_ = 1;
    }

    ++clients_;
    AshikaseSetEnabled(true, false);

    if (SBA_available())
        SBA_addStatusBarImage(const_cast<char *>("Veency"));
    else if ($SBStatusBarController != nil)
        [[$SBStatusBarController sharedStatusBarController] addStatusBarItem:@"Veency"];
    else if (UIApplication *app = [UIApplication sharedApplication])
        [app addStatusBarImageNamed:@"Veency"];
}

+ (void) performSetup:(NSThread *)thread {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
    [thread autorelease];
    VNCSetup();
    VNCEnabled();
    [pool release];
}

@end

MSInstanceMessage2(void, VNCAlertItem, alertSheet,buttonClicked, id, sheet, int, button) {
    [condition_ lock];

    switch (button) {
        case 1:
            action_ = RFB_CLIENT_ACCEPT;

            @synchronized (condition_) {
                [VNCBridge registerClient];
            }
        break;

        case 2:
            action_ = RFB_CLIENT_REFUSE;
        break;
    }

    [condition_ signal];
    [condition_ unlock];
    [self dismiss];
}

MSInstanceMessage2(void, VNCAlertItem, configure,requirePasscodeForActions, BOOL, configure, BOOL, require) {
    UIModalView *sheet([self alertSheet]);
    [sheet setDelegate:self];
    [sheet setTitle:DialogTitle];
    [sheet setBodyText:[NSString stringWithFormat:DialogFormat, client_->host]];
    [sheet addButtonWithTitle:DialogAccept];
    [sheet addButtonWithTitle:DialogReject];
}

MSInstanceMessage0(void, VNCAlertItem, performUnlockAction) {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:self];
}

static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static bool PurpleAllocated;
static int Level_;

static void FixRecord(GSEventRecord *record) {
    if (Level_ < 1)
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->size);
}

static void VNCSettingsScreenSize() {
    NSDictionary *settings([NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]]);

    NSNumber *divideScreenBy = [settings objectForKey:@"DivideScreenBy"];
    int divideScreenByOld=divideScreenBy_;
    divideScreenBy_ = [divideScreenBy intValue];
    if(divideScreenBy_<1 || divideScreenBy_>320) divideScreenBy_=1;
    destwidth_ = width_/divideScreenBy_;
    destheight_ = height_/divideScreenBy_;

    if(running_ && divideScreenBy_ != divideScreenByOld) {
        VNCShutDown();
        VNCSetup();
        VNCEnabled();
    }
}

static void VNCSettings() {
    NSDictionary *settings([NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]]);

    @synchronized (lock_) {
        for (NSValue *handler in handlers_)
            rfbUnregisterSecurityHandler(reinterpret_cast<rfbSecurityHandler *>([handler pointerValue]));
        [handlers_ removeAllObjects];
    }

    @synchronized (condition_) {
        if (screen_ == NULL)
            return;

        [reinterpret_cast<NSString *>(screen_->authPasswdData) release];
        screen_->authPasswdData = NULL;

        if (settings != nil)
            if (NSString *password = [settings objectForKey:@"Password"])
                if ([password length] != 0)
                    screen_->authPasswdData = [password retain];

        NSNumber *cursor = [settings objectForKey:@"ShowCursor"];
        cursor_ = cursor == nil ? true : [cursor boolValue];
        if(SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")) { 
            // iOS7 crashes with the mouse cursor
            cursor_=false; 
        }

        NSNumber *skipBlack = [settings objectForKey:@"SkipBlack"];
        skipBlack_ = skipBlack == nil ? 0 : [skipBlack intValue];

        VNCSettingsScreenSize();

        if (clients_ != 0)
            AshikaseSetEnabled(cursor_, true);
    }
}

static void VNCNotifySettings(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCSettings();
}

static rfbBool VNCCheck(rfbClientPtr client, const char *data, int size) {
    @synchronized (condition_) {
        if (NSString *password = reinterpret_cast<NSString *>(screen_->authPasswdData)) {
            NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
            rfbEncryptBytes(client->authChallenge, const_cast<char *>([password UTF8String]));
            bool good(memcmp(client->authChallenge, data, size) == 0);
            [pool release];
            return good;
        } return TRUE;
    }
}

static bool iPad1_;

struct VeencyEvent {
    struct GSEventRecord record;
    struct {
        struct GSEventRecordInfo info;
        struct GSPathInfo path;
    } data;
};

static void VNCPointer(int buttons, int x, int y, rfbClientPtr client) {
//Log("pointer event, x,y: %i,%i b:%i\n",x,y,buttons);
    if (ratio_ == 0)
        return;


    if (width_ > height_) {
        int t(x);
        x = height_ - 1 - y;
        y = t;

        if (!iPad1_) {
            x = height_ - 1 - x;
            y = width_ - 1 - y;
        }
    }

    x /= ratio_;
    y /= ratio_;
    x*=divideScreenBy_;
    y*=divideScreenBy_;

    x_ = x; y_ = y;
    int diff = buttons_ ^ buttons;
    bool twas((buttons_ & 0x1) != 0);
    bool tis((buttons & 0x1) != 0);
    buttons_ = buttons;

    rfbDefaultPtrAddEvent(buttons, x, y, client);

    // *** not working in iOS7
    if(!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")) { 
        if (Ashikase(false)) {
            AshikaseSendEvent(x, y, buttons);
            return;
        }
    }


    if ((diff & 0x10) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x10) != 0 ?
            GSEventTypeHeadsetButtonDown :
            GSEventTypeHeadsetButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x04) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x04) != 0 ?
            GSEventTypeMenuButtonDown :
            GSEventTypeMenuButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x02) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x02) != 0 ?
            GSEventTypeLockButtonDown :
            GSEventTypeLockButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if (twas != tis) {
        if(tis) {
            downFinger_=[SimulateTouch simulateTouch:0 atPoint:CGPointMake(x,y) withType:(tis?STTouchDown:STTouchUp)];
        } else {
            [SimulateTouch simulateTouch:downFinger_ atPoint:CGPointMake(x,y) withType:(tis?STTouchDown:STTouchUp)];
        }
    } else if(tis) {
        if(downFinger_>=0)
            [SimulateTouch simulateTouch:downFinger_ atPoint:CGPointMake(x,y) withType:STTouchMove];
    }
/*
    // Old version using SendEvent, SimluateTouch can do SendEvent if detected.
    CGPoint location = {x, y};
    mach_port_t purple(0);

    if (twas != tis || tis) {
        struct VeencyEvent event;

        memset(&event, 0, sizeof(event));

        event.record.type = GSEventTypeMouse;
        event.record.locationInWindow.x = x;
        event.record.locationInWindow.y = y;
        event.record.timestamp = GSCurrentEventTimestamp();
        event.record.size = sizeof(event.data);

        event.data.info.handInfo.type = twas == tis ?
            GSMouseEventTypeDragged :
        tis ?
            GSMouseEventTypeDown :
            GSMouseEventTypeUp;

        event.data.info.handInfo.x34 = 0x1;
        event.data.info.handInfo.x38 = tis ? 0x1 : 0x0;

        if (Level_ < 3)
            event.data.info.pathPositions = 1;
        else
            event.data.info.x52 = 1;

        event.data.path.x00 = 0x01;
        event.data.path.x01 = 0x02;
        event.data.path.x02 = tis ? 0x03 : 0x00;
        event.data.path.position = event.record.locationInWindow;

        mach_port_t port(0);

        if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
            NSArray *displays([server displays]);
            if (displays != nil && [displays count] != 0)
                if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                    port = [display clientPortAtPosition:location];
        }

        if (port == 0) {
            if (purple == 0)
                purple = (*GSTakePurpleSystemEventPort)();
            port = purple;
        }

        FixRecord(&event.record);
        GSSendEvent(&event.record, port);
    }
    if (purple != 0 && PurpleAllocated) {
        mach_port_deallocate(mach_task_self(), purple);
    }
*/
}

GSEventRef (*$GSEventCreateKeyEvent)(int, CGPoint, CFStringRef, CFStringRef, id, UniChar, short, short);
GSEventRef (*$GSCreateSyntheticKeyEvent)(UniChar, BOOL, BOOL);

static void VNCKeyboard(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    if (!down)
        return;


    switch (key) {
        case XK_Return: key = '\r'; break;
        case XK_BackSpace: key = 0x7f; break;
    }

    if (key > 0xfff)
        return;

    CGPoint point(CGPointMake(x_, y_));

    UniChar unicode(key);
    CFStringRef string(NULL);

    GSEventRef event0, event1(NULL);
    if ($GSEventCreateKeyEvent != NULL) {
        string = CFStringCreateWithCharacters(kCFAllocatorDefault, &unicode, 1);
        event0 = (*$GSEventCreateKeyEvent)(10, point, string, string, nil, 0, 0, 1);
        event1 = (*$GSEventCreateKeyEvent)(11, point, string, string, nil, 0, 0, 1);
    } else if ($GSCreateSyntheticKeyEvent != NULL) {
        event0 = (*$GSCreateSyntheticKeyEvent)(unicode, YES, YES);
        GSEventRecord *record(_GSEventGetGSEventRecord(event0));
        record->type = GSEventTypeKeyDown;
    } else return;

    mach_port_t port(0);

    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0)
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                port = [display clientPortAtPosition:point];
    }

    mach_port_t purple(0);

    if (port == 0) {
        if (purple == 0)
            purple = (*GSTakePurpleSystemEventPort)();
        port = purple;
    }

    if (port != 0) {
        GSSendEvent(_GSEventGetGSEventRecord(event0), port);
        if (event1 != NULL)
            GSSendEvent(_GSEventGetGSEventRecord(event1), port);
    }

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);

    CFRelease(event0);
    if (event1 != NULL)
        CFRelease(event1);
    if (string != NULL)
        CFRelease(string);
}

static void VNCDisconnect(rfbClientPtr client) {
    @synchronized (condition_) {
        if (--clients_ == 0)
            [VNCBridge performSelectorOnMainThread:@selector(removeStatusBarItem) withObject:nil waitUntilDone:YES];
    }
}

static rfbNewClientAction VNCClient(rfbClientPtr client) {
    @synchronized (condition_) {
        if (screen_->authPasswdData != NULL) {
            [VNCBridge performSelectorOnMainThread:@selector(registerClient) withObject:nil waitUntilDone:YES];
            client->clientGoneHook = &VNCDisconnect;
            return RFB_CLIENT_ACCEPT;
        }
    }

    [condition_ lock];
    client_ = client;
    [VNCBridge performSelectorOnMainThread:@selector(askForConnection) withObject:nil waitUntilDone:NO];
    while (action_ == RFB_CLIENT_ON_HOLD)
        [condition_ wait];
    rfbNewClientAction action(action_);
    action_ = RFB_CLIENT_ON_HOLD;
    [condition_ unlock];

    if (action == RFB_CLIENT_ACCEPT)
        client->clientGoneHook = &VNCDisconnect;
    return action;
}

//extern "C" bool GSSystemHasCapability(NSString *);

static CFTypeRef (*$GSSystemCopyCapability)(CFStringRef);
static CFTypeRef (*$GSSystemGetCapability)(CFStringRef);

static void VNCSetup() {
    rfbLogEnable(false);

    @synchronized (condition_) {
        int argc(1);
        char *arg0(strdup("VNCServer"));
        char *argv[] = {arg0, NULL};
/* *** -geometry does not scale the picture
        char a1[]="-geometry";
        char a2[]="300x300";
        char *argv[] = {arg0,a1,a2, NULL};
*/

        VNCSettingsScreenSize();

        screen_ = rfbGetScreen(&argc, argv, destwidth_, destheight_, BitsPerSample, 3, BytesPerPixel);
        free(arg0);

        VNCSettings();
    }

    screen_->desktopName = strdup([[[NSProcessInfo processInfo] hostName] UTF8String]);

    screen_->alwaysShared = TRUE;
    screen_->handleEventsEagerly = TRUE;
    screen_->deferUpdateTime = 1000 / 25;

    screen_->serverFormat.redShift = BitsPerSample * 2;
    screen_->serverFormat.greenShift = BitsPerSample * 1;
    screen_->serverFormat.blueShift = BitsPerSample * 0;

    $GSSystemCopyCapability = reinterpret_cast<CFTypeRef (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, "GSSystemCopyCapability"));
    $GSSystemGetCapability = reinterpret_cast<CFTypeRef (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, "GSSystemGetCapability"));

    CFTypeRef opengles2;

    if ($GSSystemCopyCapability != NULL) {
        opengles2 = (*$GSSystemCopyCapability)(CFSTR("opengles-2"));
    } else if ($GSSystemGetCapability != NULL) {
        opengles2 = (*$GSSystemGetCapability)(CFSTR("opengles-2"));
        if (opengles2 != NULL)
            CFRetain(opengles2);
    } else
        opengles2 = NULL;

    bool accelerated(opengles2 != NULL && [(NSNumber *)opengles2 boolValue]);
    if(SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")) { 
        // accelerated is supported in iOS7 but is not detected here.
        accelerated=true;
    }

    if (accelerated)
        CoreSurfaceAcceleratorCreate(NULL, NULL, &accelerator_);

    if (opengles2 != NULL)
        CFRelease(opengles2);

    if (accelerator_ != NULL)
        buffer_ = CoreSurfaceBufferCreate((CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
            @"PurpleEDRAM", kCoreSurfaceBufferMemoryRegion,
            [NSNumber numberWithBool:YES], kCoreSurfaceBufferGlobal,
            [NSNumber numberWithInt:(width_ * BytesPerPixel)], kCoreSurfaceBufferPitch,
            [NSNumber numberWithInt:width_], kCoreSurfaceBufferWidth,
            [NSNumber numberWithInt:height_], kCoreSurfaceBufferHeight,
            [NSNumber numberWithInt:'BGRA'], kCoreSurfaceBufferPixelFormat,
            [NSNumber numberWithInt:(width_ * height_ * BytesPerPixel)], kCoreSurfaceBufferAllocSize,
        nil]);
    else
        VNCBlack();

    //screen_->frameBuffer = reinterpret_cast<char *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));

    CoreSurfaceBufferLock(buffer_, 3);
    bufferData_ = reinterpret_cast<char *>(CoreSurfaceBufferGetBaseAddress(buffer_));
    CoreSurfaceBufferUnlock(buffer_);
    // let's alloc the maximum memory needed for the full screen
    if(mainFrameBuffer_==NULL)
        mainFrameBuffer_ = reinterpret_cast<rfbPixel *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));
    screen_->frameBuffer=(char *)mainFrameBuffer_;

    screen_->kbdAddEvent = &VNCKeyboard;
    screen_->ptrAddEvent = &VNCPointer;

    screen_->newClientHook = &VNCClient;
    screen_->passwordCheck = &VNCCheck;

    screen_->cursor = NULL;
}

static void VNCShutDown() {
    rfbShutdownServer(screen_, true);
    running_ = false;
}
static void VNCEnabled() {
    [lock_ lock];

    bool enabled(true);
    if (NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]])
        if (NSNumber *number = [settings objectForKey:@"Enabled"])
            enabled = [number boolValue];

    if (enabled != running_)
        if (enabled) {
            running_ = true;
            screen_->socketState = RFB_SOCKET_INIT;
            rfbInitServer(screen_);
            rfbRunEventLoop(screen_, -1, true);
        } else {
            VNCShutDown();
        }

    [lock_ unlock];
}

static void VNCNotifyEnabled(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCEnabled();
}

void (*$IOMobileFramebufferIsMainDisplay)(IOMobileFramebufferRef, int *);



static void Copy64x16BlockedImage(char *dest,const char *fromStart) {
    const char *fromEnd;
    char *to,*toLine,*toEnd,*toPtr;
    fromEnd=fromStart+(4*width_*height_);
    toEnd=dest+(4*width_*height_);
    to=dest;
    int toLineOffset=0;
    unsigned int toXOffset=0;

    toLine=to;
    const char *from=fromStart;

    while(from<fromEnd) {
        toXOffset=0;
        while(toXOffset<(width_*4)) {
            // one 16x line from image
            toLineOffset=0;
            while(toLineOffset<16) {
                toPtr=toLine+toXOffset+(4*width_*toLineOffset);
                if((toPtr+(64*4))<toEnd  && (from+(64*4))<fromEnd)
                    memcpy(toPtr,from,64*4);
                toLineOffset++;
                from+=64*4;
            }
            toXOffset+=64*4;
        }
        toLine+=16*4*width_;
    }

}

static void CopyToFrameBuffer(rfbPixel *dest,rfbPixel *from,int divideBy) {
    int size;
    int skipDots;
    rfbPixel zero[16];
    rfbPixel *fromEnd,*destUpto,*fromNextLine,*fromUpto,*fromLine,*destEnd,*destLine;

    memset(zero,0,sizeof(zero));
    destEnd=dest+(destwidth_*destheight_);

    size=width_*height_;
    skipDots=divideBy;
    if(skipDots<=0) skipDots=1;
    destUpto=dest;
    fromEnd=from+size;

    fromUpto=from;
    while(fromUpto<fromEnd && destUpto<destEnd) {
        destLine=destUpto;
        fromLine=fromUpto;
        fromNextLine=fromUpto+width_;

#if 0
//*** check for black bits line by line, makes no difference to speed
        int hasZeros=0;
        if(skipBlack_) {
            const rfbPixel *fromTest=fromUpto;
            while(fromTest<fromNextLine) {
                if(memcmp(fromTest,zero,sizeof(zero))==0) {
                    hasZeros=1;
                    break;
                }
                fromTest+=sizeof(zero)/sizeof(zero[0]);
            }
        }

        if(!hasZeros) {
#endif
            while(fromUpto<fromNextLine) {
                *destUpto=*fromUpto;
                ++destUpto;
                fromUpto+=skipDots;
            }
//        }
        fromUpto=fromLine+(width_*skipDots);
        destUpto=destLine+destwidth_;
    }
}
static int isBottomScreenBlack(const char *data) {
    const char *dataEnd=data+(width_*height_*sizeof(rfbPixel));
    int hasNonZero=0;
    int hasZero=0;
//    int width4=(width_/4)+width_;
    int width4=96;

    for(int *d=(int *)(data+(width_*(height_/8)*7)); d<(int *)dataEnd; d+=width4) { 
        if(d[0]) { ++hasNonZero;  }
        else ++hasZero;
    } 
    if((hasNonZero/2)>hasZero) { return 0; }
    return 1;
}


static bool updatingScreen=false;
static void OnLayer(IOMobileFramebufferRef fb, CoreSurfaceBufferRef layer) {
    int doUpdates=1;
    if (_unlikely(width_ == 0 || height_ == 0)) {
        CGSize size;
        IOMobileFramebufferGetDisplaySize(fb, &size);

        width_ = size.width;
        height_ = size.height;
        destwidth_ = size.width/divideScreenBy_;
        destheight_ = size.height/divideScreenBy_;

        if (width_ == 0 || height_ == 0)
            return;

        NSThread *thread([NSThread alloc]);

        [thread
            initWithTarget:[VNCBridge class]
            selector:@selector(performSetup:)
            object:thread
        ];

        [thread start];
    } else if (_unlikely(clients_ != 0)) {
        if (layer == NULL) {
/*  *** this blacking of the screen causes a mess in opengl apps.
            if (accelerator_ != NULL)
                memset(screen_->frameBuffer, 0, sizeof(rfbPixel) * width_ * height_);
            else
                VNCBlack();
*/
        } else {
//Log("Accelerator_:%x\n",accelerator_);
            if (accelerator_ != NULL) {
//                CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);

                if(!skipBlack_ && !divideScreenBy_) {
                    screen_->frameBuffer=(char *)bufferData_;
                    CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options_);
                } else {
                    screen_->frameBuffer=(char *)mainFrameBuffer_;
                    int ok=1;
                    CoreSurfaceBufferLock(buffer_, 3);
                    CoreSurfaceAcceleratorTransferSurface(accelerator_, layer, buffer_, options2_);

                    if(skipBlack_) {
                        usleep(skipBlack_);
                        ok=isBottomScreenBlack(bufferData_)?0:1;
                    }
                    if(ok) {
                        if(divideScreenBy_>1) {
                            CopyToFrameBuffer(mainFrameBuffer_,(rfbPixel *)bufferData_,divideScreenBy_);
                        } else {
                            memcpy(mainFrameBuffer_,bufferData_,width_*height_*sizeof(rfbPixel));
                        }
                    } else { 
                        doUpdates=0;
                    }
                }

            } else {
                if(updatingScreen) return;
                updatingScreen=true;
                CoreSurfaceBufferLock(layer, 2);
                @try {
                    rfbPixel *data(reinterpret_cast<rfbPixel *>(CoreSurfaceBufferGetBaseAddress(layer)));
                    if(skipBlack_) {
                        if(isBottomScreenBlack((const char *)data)) {
                            return;
                        }
                    }

                    CoreSurfaceBufferFlushProcessorCaches(layer);

                    /*rfbPixel corner(data[0]);
                    data[0] = 0;
                    data[0] = corner;*/

    //                screen_->frameBuffer = const_cast<char *>(reinterpret_cast<volatile char *>(data));

                    const char *x = const_cast<char *>(reinterpret_cast<volatile char *>(data));
                    if(divideScreenBy_==1) {
                        Copy64x16BlockedImage((char *)mainFrameBuffer_,x);
                    } else {
                        if(correctedBlocksBuffer_==NULL)
                            correctedBlocksBuffer_ = reinterpret_cast<rfbPixel *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));
//~~~ When using camera, opengl, etc. apps.  Any access to  the pointer returned from CoreSurfaceBufferGetBaseAddress crashes
                        Copy64x16BlockedImage((char *)correctedBlocksBuffer_,x);
                        CopyToFrameBuffer(mainFrameBuffer_,(rfbPixel *)correctedBlocksBuffer_,divideScreenBy_);
                    }
                } 
                @finally {
                    CoreSurfaceBufferUnlock(layer);
                    updatingScreen=false;
                }

//    memcpy(mainFrameBuffer_,x,(4*640*200));
            }
        }
        if(doUpdates)
            rfbMarkRectAsModified(screen_, 0, 0, destwidth_, destheight_);
    }
}

static bool wait_ = false;

MSHook(kern_return_t, IOMobileFramebufferSwapSetLayer,
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
) {
    int main(false);

    if (_unlikely(buffer == NULL))
        main = fb == main_;
    else if (_unlikely(fb == NULL))
        main = false;
    else if ($IOMobileFramebufferIsMainDisplay == NULL)
        main = true;
    else
        (*$IOMobileFramebufferIsMainDisplay)(fb, &main);

    if (_likely(main)) {
        main_ = fb;
        if (wait_)
            layer_ = buffer;
        else
            OnLayer(fb, buffer);
    }

    return _IOMobileFramebufferSwapSetLayer(fb, layer, buffer, bounds, frame, flags);
}

// XXX: beg rpetrich for the type of this function
extern "C" void *IOMobileFramebufferSwapWait(IOMobileFramebufferRef, void *, unsigned);

MSHook(void *, IOMobileFramebufferSwapWait, IOMobileFramebufferRef fb, void *arg1, unsigned flags) {
    void *value(_IOMobileFramebufferSwapWait(fb, arg1, flags));
    if (fb == main_)
        OnLayer(fb, layer_);
    return value;
}

MSHook(void, rfbRegisterSecurityHandler, rfbSecurityHandler *handler) {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    @synchronized (lock_) {
        [handlers_ addObject:[NSValue valueWithPointer:handler]];
        _rfbRegisterSecurityHandler(handler);
    }

    [pool release];
}

template <typename Type_>
static void dlset(Type_ &function, const char *name) {
    function = reinterpret_cast<Type_>(dlsym(RTLD_DEFAULT, name));
}

MSInitialize {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    MSHookSymbol(GSTakePurpleSystemEventPort, "_GSGetPurpleSystemEventPort");
    if (GSTakePurpleSystemEventPort == NULL) {
        MSHookSymbol(GSTakePurpleSystemEventPort, "_GSCopyPurpleSystemEventPort");
        PurpleAllocated = true;
    }

    if (dlsym(RTLD_DEFAULT, "GSLibraryCopyGenerationInfoValueForKey") != NULL)
        Level_ = 3;
    else if (dlsym(RTLD_DEFAULT, "GSKeyboardCreate") != NULL)
        Level_ = 2;
    else if (dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId") != NULL)
        Level_ = 1;
    else
        Level_ = 0;

    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char machine[size];
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    iPad1_ = strcmp(machine, "iPad1,1") == 0;

    dlset($GSEventCreateKeyEvent, "GSEventCreateKeyEvent");
    dlset($GSCreateSyntheticKeyEvent, "_GSCreateSyntheticKeyEvent");
    dlset($IOMobileFramebufferIsMainDisplay, "IOMobileFramebufferIsMainDisplay");

    MSHookFunction((void *)&IOMobileFramebufferSwapSetLayer, MSHake2(IOMobileFramebufferSwapSetLayer));
    MSHookFunction(&rfbRegisterSecurityHandler, MSHake(rfbRegisterSecurityHandler));

    if (wait_)
        MSHookFunction(&IOMobileFramebufferSwapWait, MSHake(IOMobileFramebufferSwapWait));

    if ($SBAlertItem != nil) {
        $VNCAlertItem = objc_allocateClassPair($SBAlertItem, "VNCAlertItem", 0);
        MSAddMessage2(VNCAlertItem, "v@:@i", alertSheet,buttonClicked);
        MSAddMessage2(VNCAlertItem, "v@:cc", configure,requirePasscodeForActions);
        MSAddMessage0(VNCAlertItem, "v@:", performUnlockAction);
        objc_registerClassPair($VNCAlertItem);
    }

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifyEnabled, CFSTR("com.saurik.Veency-Enabled"), NULL, 0
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifySettings, CFSTR("com.saurik.Veency-Settings"), NULL, 0
    );

    condition_ = [[NSCondition alloc] init];
    lock_ = [[NSLock alloc] init];
    handlers_ = [[NSMutableSet alloc] init];

    bool value;

    value = true;
    cfTrue_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    value = false;
    cfFalse_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    cfEvent_ = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&event_), sizeof(event_), kCFAllocatorNull);

    options_ = (CFDictionaryRef) [[NSDictionary dictionaryWithObjectsAndKeys:
    nil] retain];

    [pool release];
}
/* vim: set ts=4 sw=4 expandtab: */
