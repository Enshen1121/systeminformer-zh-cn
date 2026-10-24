#include "zh_ui.h"
#include "zh_exports.h"
#include <stdio.h>

typedef PVOID (NTAPI *REGISTER_PLUGIN)(const ZH_STRINGREF *,PVOID,ZH_PLUGIN_INFORMATION **);
typedef PVOID (NTAPI *GET_CALLBACK)(ULONG);
typedef VOID (NTAPI *REGISTER_CALLBACK)(PVOID,VOID (NTAPI *)(PVOID,PVOID),PVOID,ZH_CALLBACK_REGISTRATION *);
typedef PVOID (NTAPI *INVOKE_MAIN)(ULONG,PVOID,PVOID);
static GET_CALLBACK GetCallback;
static REGISTER_CALLBACK RegisterCallback;
static INVOKE_MAIN InvokeMain;
static ZH_CALLBACK_REGISTRATION Registrations[32];
static ULONG RegistrationCount;
static HINSTANCE Module;
static LONG ControlChanges, MenuChanges;
static WCHAR StatusPath[4096];
static __declspec(thread) UINT_PTR Timer;
static __declspec(thread) BOOL Busy;
static __declspec(thread) ULONG Ticks;

#ifdef _WIN64
_Static_assert(sizeof(ZH_MENU_ITEM)==72,"menu ABI");
_Static_assert(sizeof(ZH_CALLBACK_REGISTRATION)==40,"callback ABI");
_Static_assert(sizeof(ZH_TREE_COLUMN)==48,"TreeNew ABI");
#else
_Static_assert(sizeof(ZH_MENU_ITEM)==40,"menu ABI");
_Static_assert(sizeof(ZH_CALLBACK_REGISTRATION)==24,"callback ABI");
_Static_assert(sizeof(ZH_TREE_COLUMN)==40,"TreeNew ABI");
#endif

static BOOL HostVersionMatches(void)
{
    WCHAR path[4096];
    DWORD ignored = 0, size;
    BOOL valid = FALSE;
    PVOID data;
    VS_FIXEDFILEINFO *info;
    UINT infoSize;
    if (!GetModuleFileNameW(NULL,path,4096)) return FALSE;
    size = GetFileVersionInfoSizeW(path,&ignored);
    if (!size || !(data=HeapAlloc(GetProcessHeap(),0,size))) return FALSE;
    if (GetFileVersionInfoW(path,0,size,data) &&
        VerQueryValueW(data,L"\\",(PVOID *)&info,&infoSize) && infoSize >= sizeof(*info))
        valid = info->dwFileVersionMS == MAKELONG(0,4) &&
                info->dwFileVersionLS == MAKELONG(138,26241);
    HeapFree(GetProcessHeap(),0,data);
    return valid;
}

static void WriteStatus(PCWSTR stage)
{
    FILE *file;
    if (!StatusPath[0] || _wfopen_s(&file,StatusPath,L"w, ccs=UTF-8")) return;
    fwprintf(file,L"{\"stage\":\"%ls\",\"pid\":%lu,\"controls\":%ld,\"menus\":%ld,\"ticks\":%lu}\n",
        stage,GetCurrentProcessId(),InterlockedCompareExchange(&ControlChanges,0,0),
        InterlockedCompareExchange(&MenuChanges,0,0),Ticks);
    fclose(file);
}

static void InitializeStatusPath(void)
{
    WCHAR *separator;
    if (!GetModuleFileNameW(Module,StatusPath,4096)) { StatusPath[0]=0; return; }
    separator=wcsrchr(StatusPath,L'\\');
    if (!separator) { StatusPath[0]=0; return; }
    *separator=0;
    separator=wcsrchr(StatusPath,L'\\');
    if (!separator) { StatusPath[0]=0; return; }
    *separator=0;
    if (wcscat_s(StatusPath,4096,L"\\work\\runtime-status.json")) StatusPath[0]=0;
}

static BOOL CALLBACK TranslateChild(HWND window,LPARAM context)
{
    (void)context;
    InterlockedExchangeAdd(&ControlChanges,(LONG)ZhTranslateControl(window));
    return TRUE;
}

static BOOL CALLBACK TranslateTopWindow(HWND window,LPARAM context)
{
    HMENU menu;
    ULONG changed=0;
    (void)context;
    TranslateChild(window,0);
    EnumChildWindows(window,TranslateChild,0);
    menu=GetMenu(window);
    if (menu)
    {
        // The application's main menu is created by PhEMenuToHMenu2. Its
        // item data is PH_EMENU_ITEM, as verified in the matching source.
        for (int index=0; ZhIsMainWindow(window) && index<GetMenuItemCount(menu); index++)
        {
            MENUITEMINFOW item={0};
            item.cbSize=sizeof(item); item.fMask=MIIM_DATA;
            if (GetMenuItemInfoW(menu,index,TRUE,&item) && item.dwItemData)
            {
                ZH_MENU_ITEM *entry=(ZH_MENU_ITEM *)item.dwItemData;
                if (entry->Flags & ZH_MENU_MAINMENU) changed+=ZhTranslateMenu(entry);
            }
        }
        changed+=ZhTranslateNativeMenu(menu);
        if (changed) DrawMenuBar(window);
        InterlockedExchangeAdd(&MenuChanges,(LONG)changed);
    }
    return TRUE;
}

static VOID CALLBACK OnTimer(HWND window,UINT message,UINT_PTR id,DWORD time)
{
    (void)window; (void)message; (void)id; (void)time;
    if (Busy) return;
    Busy=TRUE;
    EnumThreadWindows(GetCurrentThreadId(),TranslateTopWindow,0);
    Ticks++;
    if (Ticks==1 || Ticks==4 || Ticks==32) WriteStatus(L"active");
    Busy=FALSE;
}

static VOID NTAPI WindowCallback(PVOID parameter,PVOID context)
{
    (void)parameter; (void)context;
    // Public PH_MAINWINDOW_CALLBACK_TYPE_WINDOW_HANDLE = 26 in this version.
    if (InvokeMain) ZhSetMainWindow((HWND)InvokeMain(26,NULL,NULL));
    if (!Timer) Timer=SetTimer(NULL,0,750,OnTimer);
}

static VOID NTAPI MenuCallback(PVOID parameter,PVOID context)
{
    (void)context;
    if (parameter)
    {
        ZH_MENU_ITEM *menu=*(ZH_MENU_ITEM **)parameter;
        InterlockedExchangeAdd(&MenuChanges,(LONG)ZhTranslateMenu(menu));
    }
    WindowCallback(NULL,NULL);
}

static VOID NTAPI OptionsCallback(PVOID parameter,PVOID context)
{
    // PH_PLUGIN_OPTIONS_POINTERS starts with the confirmed options HWND.
    if (parameter) ZhSetOptionsWindow(*(HWND *)parameter);
    WindowCallback(NULL,context);
}

static void Register(ULONG callback,VOID (NTAPI *function)(PVOID,PVOID))
{
    PVOID list=GetCallback(callback);
    if (list && RegistrationCount < sizeof(Registrations)/sizeof(Registrations[0]))
        RegisterCallback(list,function,NULL,&Registrations[RegistrationCount++]);
}

BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID reserved)
{
    (void)reserved;
    if (reason==DLL_PROCESS_ATTACH)
    {
        HMODULE host=GetModuleHandleW(NULL);
        REGISTER_PLUGIN registerPlugin;
        ZH_PLUGIN_INFORMATION *info=NULL;
        ZH_STRINGREF name={sizeof(L"Local.ZhCnLocalization")-sizeof(WCHAR),L"Local.ZhCnLocalization"};
        union {
            FARPROC raw;
            REGISTER_PLUGIN registration;
            GET_CALLBACK get;
            REGISTER_CALLBACK callback;
            INVOKE_MAIN main;
        } symbol;
        const ULONG windowEvents[]={0,4,7,8,17,18,19,20,22,24,27,29,35};
        const ULONG menuEvents[]={5,9,10,11,12,13,14,15,16,33};
        if (!HostVersionMatches()) return FALSE;
        // Official release images export this public plugin API by ordinal.
        // These values are pinned to the version checked above, not guessed.
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHREGISTERPLUGINBYNAME)); registerPlugin=symbol.registration;
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHGETGENERALCALLBACK)); GetCallback=symbol.get;
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHREGISTERCALLBACK)); RegisterCallback=symbol.callback;
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHPLUGININVOKEWINDOWCALLBACK)); InvokeMain=symbol.main;
        if (!registerPlugin || !GetCallback || !RegisterCallback || !InvokeMain) return FALSE;
        if (!registerPlugin(&name,instance,&info) || !info) return FALSE;
        Module=instance;
        info->DisplayName=L"简体中文界面";
        info->Author=L"Local localization project";
        info->Description=L"为当前版本补充中文菜单、标签页和列标题；保留数据、命令 ID 和原始文件。";
        info->HasOptions=FALSE;
        for (ULONG i=0;i<sizeof(windowEvents)/sizeof(windowEvents[0]);i++) Register(windowEvents[i],WindowCallback);
        for (ULONG i=0;i<sizeof(menuEvents)/sizeof(menuEvents[0]);i++) Register(menuEvents[i],MenuCallback);
        Register(34,OptionsCallback);
        InitializeStatusPath();
        WriteStatus(L"loaded");
    }
    return TRUE;
}
