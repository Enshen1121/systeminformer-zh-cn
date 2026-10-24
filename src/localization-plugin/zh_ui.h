// Minimal public ABI definitions from winsiderss/systeminformer,
// commit 99a0d28e091878967a804ac9ea2fe22f2c1fdadb (MIT).
// This plugin is deliberately limited to the matching 4.0.26241.138 build.
#pragma once
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <wchar.h>
#include <stddef.h>

typedef struct { SIZE_T Length; PWSTR Buffer; } ZH_STRINGREF;
typedef struct { ULONG Count, AllocatedCount; PVOID *Items; } ZH_LIST;
typedef struct ZH_MENU_ITEM ZH_MENU_ITEM;
struct ZH_MENU_ITEM {
    ULONG Flags, Id;
    PWSTR Text;
    HBITMAP Bitmap;
    PVOID Parameter, Context;
    PVOID DeleteFunction, DelayFunction;
    ZH_MENU_ITEM *Parent;
    ZH_LIST *Items;
};
typedef struct {
    LIST_ENTRY ListEntry;
    VOID (NTAPI *Function)(PVOID, PVOID);
    PVOID Context;
    LONG Busy;
    BOOLEAN Unregistering, Reserved;
    USHORT Flags;
} ZH_CALLBACK_REGISTRATION;
typedef struct {
    PCWSTR DisplayName, Author, Description, Url;
    BOOLEAN HasOptions;
    BOOLEAN Reserved[3];
    PVOID Interface;
} ZH_PLUGIN_INFORMATION;
typedef struct {
    ULONG Flags, Id;
    PVOID Context;
    PCWSTR Text;
    LONG Width;
    ULONG Alignment, DisplayIndex, TextFlags;
    LONG ViewIndex, ViewX;
} ZH_TREE_COLUMN;

#define ZH_MENU_TEXT_OWNED 0x80000000UL
#define ZH_MENU_MAINMENU 0x400000UL
#define ZH_TN_GETCOLUMN (WM_USER + 7)
#define ZH_TN_SETCOLUMN (WM_USER + 8)
#define ZH_TN_GETMAXID (WM_USER + 21)
#define ZH_TN_COLUMN_TEXT 0x2
#define ZH_TAB_FIRST (WM_USER + 0x600)
#define ZH_TAB_COUNT (ZH_TAB_FIRST + 4)
#define ZH_TAB_GETTEXT (ZH_TAB_FIRST + 7)
#define ZH_TAB_SETTEXT (ZH_TAB_FIRST + 8)

PCWSTR ZhLookup(PCWSTR text);
ULONG ZhTranslateMenu(ZH_MENU_ITEM *menu);
ULONG ZhTranslateNativeMenu(HMENU menu);
ULONG ZhTranslateControl(HWND window);
void ZhSetMainWindow(HWND window);
BOOL ZhIsMainWindow(HWND window);
void ZhSetOptionsWindow(HWND window);
