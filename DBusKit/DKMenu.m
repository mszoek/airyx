/*
 * Airyx DBusKit: a simple Cocoa binding to libdbus
 *
 * Copyright (C) 2021 Zoe Knox <zoe@pixin.net>
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#define _BuildingFramework
#import "DKMenu.h"
#import <Foundation/NSString.h>
#import <Foundation/NSPlatform.h>
#import <AppKit/NSMenu.h>

static const char *REGISTRAR_INTERFACE = "com.canonical.AppMenu.Registrar";
static const char *REGISTRAR_PATH = "/com/canonical/AppMenu/Registrar";
static NSString *DBUSMENU_INTERFACE = @"com.canonical.dbusmenu";
static NSString *DBUSMENU_PATH = @"/org/airyx/Airyx/MenuBar";

struct _entry {
    int32_t item;
    const char *label;
} entries[] = {
    {20, "Menu 1"},
    {21, "Menu 2"}
};

// Let's get recursive... let's get recursive in here
void enumerateMenuLayout(DKMessageIterator *iterator, NSMenu *menu, int32_t itemNumber, int curDepth, int maxDepth) {
    DKMessageIterator *outerStruct = [iterator openStruct];
    [outerStruct appendBasic:DBUS_TYPE_INT32 value:&itemNumber];

    // properties map for the root node
    DKMessageIterator *properties = [outerStruct openArray:"{sv}"];
    const char *s = "submenu";
    [properties appendDictEntry:@"children-display" variantType:DBUS_TYPE_STRING value:&s];
    [properties close];
    [properties release];

    // menu entries as variant array
    DKMessageIterator *menuItems = [outerStruct openArray:"v"];

    NSArray *items = [menu itemArray];
    for(int i = 0; i < [menu numberOfItems]; ++i) {
        DKMessageIterator *variant = [menuItems openVariant:"(ia{sv}av)"];
        DKMessageIterator *innerStruct = [variant openStruct];

        NSMenuItem *item = [items objectAtIndex:i];
        ++itemNumber;
        [innerStruct appendBasic:DBUS_TYPE_INT32 value:&itemNumber];
        properties = [innerStruct openArray:"{sv}"];
        s = [[item title] UTF8String];
        [properties appendDictEntry:@"label" variantType:DBUS_TYPE_STRING value:&s];
        if([item hasSubmenu]) {
            s = "submenu";
            [properties appendDictEntry:@"children-display" variantType:DBUS_TYPE_STRING value:&s];
        }
        s = ([item enabled] ? "true" : "false");
        [properties appendDictEntry:@"enabled" variantType:DBUS_TYPE_STRING value:&s];
        s = ([item hidden] ? "false" : "true"); // translate "hidden" to "visible"
        [properties appendDictEntry:@"visible" variantType:DBUS_TYPE_STRING value:&s];
        [properties close];
        [properties release];

        // child items as variant array
        properties = [innerStruct openArray:"v"];
        if([item hasSubmenu] && curDepth < maxDepth) {
            DKMessageIterator *innerVariant = [properties openVariant:"(ia{sv}av)"];
            enumerateMenuLayout(innerVariant, [item submenu], ++itemNumber, curDepth+1, maxDepth);
            [innerVariant close];
        }
        [properties close];
        [properties release];

        [innerStruct close];
        [innerStruct release];
        [variant close];
        [variant release];
    }

    [menuItems close];
    [menuItems release];
    [outerStruct close];
    [outerStruct release];
}

@implementation DKMenu
- initWithConnection: (DKConnection *)conn {
    connection = conn;
    layoutVersion = 1;
    menu = nil;

    srandomdev();
    menuObjectPath = [NSString stringWithFormat:@"%@/%08x",DBUSMENU_PATH, random()];

    [connection registerHandlerForInterface:self interface:DBUSMENU_INTERFACE];
    _pathWasRegistered = [connection registerObjectPath:menuObjectPath];
    if(! _pathWasRegistered) {
        [connection unregisterObjectPath:menuObjectPath];
        NSLog(@"%@ Attemping to take over stale registration",self);
        _pathWasRegistered = [connection registerObjectPath:menuObjectPath];
        if(! _pathWasRegistered) {
            NSLog(@"%@ cannot register object path for menus!",self);
        }
    }
    return [self autorelease];
}

- (oneway void) release {
    [connection unregisterHandlerForInterface:DBUSMENU_INTERFACE];
    if(_pathWasRegistered) {
        [connection unregisterObjectPath:menuObjectPath];
        [connection flush];
        _pathWasRegistered = NO;
    }
}

- (void) setMenu: (NSMenu *)aMenu {
    menu = aMenu;
    [self layoutDidUpdate];
}

- (DBusHandlerResult) messageFunction: (DKMessage *)msg {
    NSString *member = [msg member];
    NSString *signature = [msg signature];

    fprintf(stderr, "%08x messageFunction interface = %s ",self,[DBUSMENU_INTERFACE UTF8String]);
    fprintf(stderr, "member = %s, signature = %s\n",[member UTF8String],[signature UTF8String]);

    if([member isEqualToString:@"GetLayout"] && [signature isEqualToString:@"iias"]) {
        [self getLayout:msg];
        return DBUS_HANDLER_RESULT_HANDLED;
    } else if([member isEqualToString:@"AboutToShow"] && [signature isEqualToString:@"i"]) {
        [self aboutToShow:msg];
        return DBUS_HANDLER_RESULT_HANDLED;
    } else if([member isEqualToString:@"Event"] && [signature isEqualToString:@"isvu"]) {
        [self event:msg];
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

- (NSString *)objectPath {
	return menuObjectPath;
}

- (BOOL) registerWindow: (uint32_t)windowID objectPath: (NSString *)path {
    DKMessage *message = [[DKMessage alloc] initMethodCall:"RegisterWindow" interface:REGISTRAR_INTERFACE path:REGISTRAR_PATH destination:REGISTRAR_INTERFACE];
    [message appendArg:&windowID type:DBUS_TYPE_UINT32];
    const char *szpath = [path UTF8String];
    [message appendArg:&szpath type:DBUS_TYPE_OBJECT_PATH];
    DKMessage *reply = [connection sendWithReplyAndBlock:message];

    if(reply == nil) {
        return NO;
    }
    return YES;
}

- (BOOL) registerWindow: (uint32_t)windowID {
    return [self registerWindow:windowID objectPath:menuObjectPath];
}

- (BOOL) unregisterWindow: (uint32_t)windowID {
    DKMessage *message = [[DKMessage alloc] initMethodCall:"UnregisterWindow" interface:REGISTRAR_INTERFACE path:REGISTRAR_PATH destination:REGISTRAR_INTERFACE];
    [message appendArg:&windowID type:DBUS_TYPE_UINT32];
    DKMessage *reply = [connection sendWithReplyAndBlock:message];

    if(reply == nil) {
        return NO;
    }
    return YES;
}

- (NSString *) getMenuForWindow: (uint32_t)windowID {
    DKMessage *message = [[DKMessage alloc] initMethodCall:"GetMenuForWindow" interface:REGISTRAR_INTERFACE path:REGISTRAR_PATH destination:REGISTRAR_INTERFACE];
    [message appendArg:&windowID type:DBUS_TYPE_UINT32];
    DKMessage *reply = [connection sendWithReplyAndBlock:message];

    if(reply == nil) {
        return nil;
    }

    const char *service = NULL;
    const char *objectPath = NULL;
    dbus_message_get_args([reply _getMessage], NULL, DBUS_TYPE_STRING, &service, DBUS_TYPE_OBJECT_PATH, &objectPath, DBUS_TYPE_INVALID);
    NSString *result = [[NSString stringWithFormat:@"%s:%s", service, objectPath] autorelease];
    return result;
}

- (void) getLayout: (DKMessage *)message {
    int rootID = 0;
    int recursionDepth = -1;

    dbus_message_get_args([message _getMessage], NULL, DBUS_TYPE_INT32, &rootID, DBUS_TYPE_INT32, &recursionDepth, DBUS_TYPE_INVALID);
    // NSLog(@"getLayout called for %d with depth %d!", rootID, recursionDepth);
    DKMessage *reply = [[DKMessage alloc] initReply:message];

    [reply appendArg:&layoutVersion type:DBUS_TYPE_UINT32];

    DKMessageIterator *rootIter = [reply appendIterator];
    enumerateMenuLayout(rootIter, menu, rootID, 1, recursionDepth);
    [connection send:reply];
}

- (void) layoutDidUpdate {
    DKMessage *update = [[DKMessage alloc] initSignal:"LayoutUpdated"
        interface:[DBUSMENU_INTERFACE UTF8String] path:[menuObjectPath UTF8String]];

    uint32_t val = layoutVersion;
    [update appendArg:&val type:DBUS_TYPE_UINT32];
    val = 0;
    [update appendArg:&val type:DBUS_TYPE_UINT32];

    [connection send:update];
    ++layoutVersion;
}

// FIXME: not really implemented or currently used
- (void) itemPropertiesDidUpdate {
    DKMessage *update = [[DKMessage alloc] initSignal:"ItemsPropertiesUpdated"
        interface:[DBUSMENU_INTERFACE UTF8String] path:[menuObjectPath UTF8String]];

    DKMessageIterator *rootIter = [update appendIterator];
    DKMessageIterator *outerArray = [rootIter openArray:"(ia{sv})"]; 

    int numItems = (sizeof(entries) / sizeof(struct _entry));
    for(int i = 0; i < numItems; ++i) {
        DKMessageIterator *itemStruct = [outerArray openStruct];
        [itemStruct appendBasic:DBUS_TYPE_INT32 value:&(entries[i].item)];
        DKMessageIterator *properties = [itemStruct openArray:"{sv}"];
        [properties appendDictEntry:@"label" variantType:DBUS_TYPE_STRING value:&(entries[i].label)];
        int enabled = 1;
        [properties appendDictEntry:@"enabled" variantType:DBUS_TYPE_BOOLEAN value:&enabled];
        [properties close];
        [properties release];
        [itemStruct close];
        [itemStruct release];
    }
    [outerArray close];
    [outerArray release];

    outerArray = [rootIter openArray:"v"];
    [outerArray close];
    [outerArray release];

    [connection send:update];
}

- (void) aboutToShow: (DKMessage *)message {
    int32_t item = 0;
    dbus_message_get_args([message _getMessage], NULL, DBUS_TYPE_INT32, &item, DBUS_TYPE_INVALID);
    fprintf(stderr, "aboutToShow %d\n",item);
    DKMessage *reply = [[DKMessage alloc] initReply:message];
    DKMessageIterator *rootIter = [reply appendIterator];
    int val = 0;
    [rootIter appendBasic:DBUS_TYPE_BOOLEAN value:&val];
    [connection send:reply];
}

// FIXME: we probably need to do stuff for these events
- (void) event: (DKMessage *)message {
    int32_t item = 0;
    const char *s = NULL;
    dbus_message_get_args([message _getMessage], NULL, DBUS_TYPE_INT32, &item, DBUS_TYPE_STRING, &s, DBUS_TYPE_INVALID);
    fprintf(stderr, "event %d %s\n",item,s);
    DKMessage *reply = [[DKMessage alloc] initReply:message];
    [connection send:reply];
}

@end
