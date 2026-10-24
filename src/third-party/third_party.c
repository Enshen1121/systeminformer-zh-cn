#include "../localization-plugin/zh_ui.h"
#include "../localization-plugin/zh_exports.h"
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct PAGE PAGE;
struct PAGE {
    ZH_STRINGREF Name; ULONG Flags;
    BOOLEAN (NTAPI *Callback)(PAGE *,ULONG,PVOID,PVOID);
    PVOID Context; LONG Index; ULONG StateFlags; PVOID Reserved[2]; HWND WindowHandle;
};
typedef PVOID (NTAPI *REGISTER_PLUGIN)(const ZH_STRINGREF *,PVOID,ZH_PLUGIN_INFORMATION **);
typedef PVOID (NTAPI *GET_CALLBACK)(ULONG);
typedef VOID (NTAPI *REGISTER_CALLBACK)(PVOID,VOID (NTAPI *)(PVOID,PVOID),PVOID,ZH_CALLBACK_REGISTRATION *);
typedef PVOID (NTAPI *INVOKE_MAIN)(ULONG,PVOID,PVOID);
static HINSTANCE Module;
static INVOKE_MAIN InvokeMain;
static PVOID (NTAPI *CreateTabPage)(PVOID);
static ZH_CALLBACK_REGISTRATION Registration;
static UINT_PTR CreateTimer;
static PAGE *Page;
static HWND Panel,List,Status,Buttons[8];
static WCHAR Root[4096],Base[4096],Session[80];
static HANDLE Worker;
static BOOL Applying,Destroying;
static UINT Dpi=96;
typedef struct { WCHAR *Cells[10]; } ROW;
static ROW Rows[4096];
static int RowCount;
#define ID_REFRESH 100
#define ID_ADMIN 101
#define ID_ALL 102
#define ID_NONE 103
#define ID_DISABLE 104
#define ID_CLOSE 105
#define ID_STARTUP 106
#define ID_REPORT 107
#define SCALE(x) MulDiv((x),(int)Dpi,96)
#ifdef _WIN64
_Static_assert(sizeof(PAGE)==72,"PH_MAIN_TAB_PAGE x64 ABI");
#else
_Static_assert(sizeof(PAGE)==40,"PH_MAIN_TAB_PAGE x86 ABI");
#endif

static WCHAR *ReadText(PCWSTR path)
{
    HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,0,NULL);
    DWORD size,read=0; WCHAR *data;
    if (f==INVALID_HANDLE_VALUE) return NULL;
    size=GetFileSize(f,NULL);
    if (size==INVALID_FILE_SIZE || size>32*1024*1024 || (size&1)) { CloseHandle(f); return NULL; }
    data=calloc((SIZE_T)size+sizeof(WCHAR),1);
    if (data && (!ReadFile(f,data,size,&read,NULL) || read!=size)) { free(data); data=NULL; }
    CloseHandle(f); return data;
}
static BOOL MakePath(WCHAR *path,SIZE_T count,PCWSTR suffix)
{
    return _snwprintf_s(path,count,_TRUNCATE,L"%ls%ls",Base,suffix)>=0;
}
static void ClearRows(void)
{
    ListView_DeleteAllItems(List);
    for (int i=0;i<RowCount;i++) for (int c=0;c<10;c++) { free(Rows[i].Cells[c]); Rows[i].Cells[c]=NULL; }
    RowCount=0;
}
static BOOL Protected(int i) { return i<0 || i>=RowCount || !Rows[i].Cells[8] || Rows[i].Cells[8][0]!=0; }
static void LoadRows(void)
{
    WCHAR path[4096],*text,*line,*next;
    MakePath(path,4096,L".tsv"); text=ReadText(path);
    if (!text) return;
    SendMessageW(List,WM_SETREDRAW,FALSE,0); ClearRows();
    line=text; if (*line==0xfeff) line++;
    while (*line && RowCount<4096)
    {
        WCHAR *cell=line; int count=0; ROW row={0};
        next=wcschr(line,L'\n'); if (next) *next++=0;
        SIZE_T n=wcslen(line); if (n && line[n-1]==L'\r') line[n-1]=0;
        for (int c=0;c<10;c++)
        {
            WCHAR *sep=wcschr(cell,L'\t'); if (sep) *sep=0;
            row.Cells[c]=_wcsdup(cell); if (!row.Cells[c]) break;
            count++; if (!sep) break; cell=sep+1;
        }
        if (count==10)
        {
            LVITEMW item={0}; item.mask=LVIF_TEXT|LVIF_PARAM; item.iItem=RowCount; item.pszText=row.Cells[1]; item.lParam=RowCount;
            Rows[RowCount]=row; int index=ListView_InsertItem(List,&item);
            const int fields[]={2,3,4,5,6,7,8,9};
            for (int c=0;c<8;c++) ListView_SetItemText(List,index,c+1,row.Cells[fields[c]]);
            RowCount++;
        }
        else { for (int c=0;c<count;c++) free(row.Cells[c]); }
        if (!next) break; line=next;
    }
    free(text); SendMessageW(List,WM_SETREDRAW,TRUE,0); InvalidateRect(List,NULL,TRUE);
}
static void SetBusy(BOOL busy)
{
    for (int i=0;i<8;i++) EnableWindow(Buttons[i],!busy);
    EnableWindow(List,!busy);
}
static BOOL StartWorker(BOOL apply,BOOL admin)
{
    WCHAR exe[4096],script[4096],args[10000],path[4096];
    SHELLEXECUTEINFOW si={0};
    if (Worker) return FALSE;
    GetWindowsDirectoryW(exe,4096); wcscat_s(exe,4096,L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    _snwprintf_s(script,4096,_TRUNCATE,L"%ls\\third-party\\backend.ps1",Root);
    _snwprintf_s(args,10000,_TRUNCATE,L"-NoProfile -ExecutionPolicy Bypass -File \"%ls\" -Mode %ls -Session %ls",script,apply?L"Apply":L"Inventory",Session);
    MakePath(path,4096,L".done"); DeleteFileW(path);
    MakePath(path,4096,L".error"); DeleteFileW(path);
    MakePath(path,4096,L".result"); DeleteFileW(path);
    si.cbSize=sizeof(si); si.fMask=SEE_MASK_NOCLOSEPROCESS|SEE_MASK_FLAG_NO_UI;
    si.hwnd=Panel; si.lpVerb=admin?L"runas":L"open"; si.lpFile=exe; si.lpParameters=args; si.nShow=SW_HIDE;
    if (!ShellExecuteExW(&si))
    {
        WCHAR error[256]; _snwprintf_s(error,256,_TRUNCATE,L"操作未开始（错误 %lu）。若取消管理员授权，本次不会更改。",GetLastError());
        SetWindowTextW(Status,error); return FALSE;
    }
    Worker=si.hProcess; Applying=apply; SetBusy(TRUE);
    SetWindowTextW(Status,apply?L"正在处理勾选项目，请等待逐项结果…":L"正在扫描进程与自启动来源…");
    SetTimer(Panel,1,250,NULL); return TRUE;
}
static BOOL WriteRequest(PCWSTR action)
{
    WCHAR path[4096]; FILE *f;
    MakePath(path,4096,L".request");
    if (_wfopen_s(&f,path,L"w, ccs=UTF-16LE")) return FALSE;
    fwprintf(f,L"%ls\n",action);
    for (int i=0;i<RowCount;i++) if (ListView_GetCheckState(List,i) && !Protected(i)) fwprintf(f,L"%ls\n",Rows[i].Cells[0]);
    return fclose(f)==0;
}
static void AppendProgramSummary(WCHAR *summary,SIZE_T capacity,PCWSTR name,PCWSTR description)
{
    WCHAR line[512];
    _snwprintf_s(line,512,_TRUNCATE,L"• %.180ls（%.260ls）\n",name,description);
    wcsncat_s(summary,capacity,line,_TRUNCATE);
}
static void Apply(PCWSTR action)
{
    WCHAR summary[12000]=L"",buffer[1024]; int selected=0,blocked=0;
    for (int i=0;i<RowCount;i++) if (ListView_GetCheckState(List,i))
    {
        if (Protected(i)) { blocked++; continue; }
        selected++;
        if (selected<=15) AppendProgramSummary(summary,10000,Rows[i].Cells[1],Rows[i].Cells[2]);
    }
    if (!selected) { MessageBoxW(Panel,blocked?L"勾选的是需要单独管理的项目。请先选择普通应用。":L"请先勾选要处理的程序。",L"第三方",MB_OK|MB_ICONINFORMATION); return; }
    if (selected>15) { _snwprintf_s(buffer,1024,_TRUNCATE,L"…共 %d 项\n",selected); wcscat_s(summary,12000,buffer); }
    wcscat_s(summary,12000,L"\n");
    wcscat_s(summary,12000,!wcscmp(action,L"startup")?L"关闭这些程序已识别的自动启动入口，保留当前进程。":!wcscmp(action,L"close")?L"结束这些程序当前的进程，未保存内容会丢失。":L"关闭这些程序的已识别自启，并结束当前进程；未保存内容会丢失。");
    wcscat_s(summary,12000,L"\n\n需要管理员权限，结果与恢复资料将逐项显示。是否继续？");
    if (MessageBoxW(Panel,summary,L"确认处理勾选项目",MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2)!=IDYES) return;
    if (!WriteRequest(action)) { MessageBoxW(Panel,L"无法保存操作请求，本次未执行。",L"第三方",MB_OK|MB_ICONERROR); return; }
    StartWorker(TRUE,TRUE);
}
static void FinishWorker(void)
{
    DWORD code=0; WCHAR path[4096],*message;
    if (!Worker || WaitForSingleObject(Worker,0)!=WAIT_OBJECT_0) return;
    GetExitCodeProcess(Worker,&code); CloseHandle(Worker); Worker=NULL; KillTimer(Panel,1); SetBusy(FALSE);
    MakePath(path,4096,code?L".error":L".done"); message=ReadText(path);
    if (message) { SetWindowTextW(Status,*message==0xfeff?message+1:message); free(message); }
    else SetWindowTextW(Status,L"后台未返回完整结果，未确认完成。请刷新或查看工作目录。");
    if (!code) LoadRows();
    if (Applying)
    {
        MakePath(path,4096,L".result"); message=ReadText(path);
        if (message) { MessageBoxW(Panel,*message==0xfeff?message+1:message,L"逐项处理结果",MB_OK|MB_ICONINFORMATION); free(message); }
        else MessageBoxW(Panel,L"后台执行失败，未获得逐项结果。请查看状态和备份记录。",L"第三方",MB_OK|MB_ICONERROR);
    }
}
static void Layout(HWND w)
{
    RECT r; GetClientRect(w,&r); int x=SCALE(8),y=SCALE(8),h=SCALE(28);
    const int widths[]={64,104,120,80,84,84,104,84};
    for (int i=0;i<8;i++)
    {
        int width=SCALE(widths[i]);
        if (x+width>r.right-SCALE(8) && x>SCALE(8)) { x=SCALE(8); y+=h+SCALE(6); }
        MoveWindow(Buttons[i],x,y,width,h,TRUE); x+=width+SCALE(6);
    }
    int top=y+h+SCALE(8),bottom=SCALE(40);
    MoveWindow(List,SCALE(8),top,max(0,r.right-SCALE(16)),max(0,r.bottom-top-bottom),TRUE);
    MoveWindow(Status,SCALE(8),max(top,r.bottom-bottom+SCALE(6)),max(0,r.right-SCALE(16)),SCALE(32),TRUE);
}
static LRESULT CALLBACK WindowProc(HWND w,UINT msg,WPARAM wp,LPARAM lp)
{
    switch (msg)
    {
    case WM_CREATE:
    {
        const PCWSTR names[]={L"刷新",L"管理员扫描",L"全选可操作项",L"清空选择",L"一键禁用",L"一键关闭",L"一键关闭自启",L"查看名单"};
        const PCWSTR columns[]={L"程序",L"描述",L"发布者",L"进程数",L"PID",L"自启动来源/状态",L"类别",L"保护说明",L"完整路径"};
        const int widths[]={155,195,200,65,145,330,110,200,450};
        Panel=w;
        for (int i=0;i<8;i++) Buttons[i]=CreateWindowExW(0,L"BUTTON",names[i],WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_PUSHBUTTON,0,0,0,0,w,(HMENU)(INT_PTR)(100+i),Module,NULL);
        List=CreateWindowExW(WS_EX_CLIENTEDGE,WC_LISTVIEWW,L"第三方程序名单",WS_CHILD|WS_VISIBLE|WS_TABSTOP|LVS_REPORT|LVS_SHOWSELALWAYS,0,0,0,0,w,(HMENU)200,Module,NULL);
        ListView_SetExtendedListViewStyle(List,LVS_EX_CHECKBOXES|LVS_EX_FULLROWSELECT|LVS_EX_DOUBLEBUFFER|LVS_EX_LABELTIP);
        for (int i=0;i<9;i++) { LVCOLUMNW c={0}; c.mask=LVCF_TEXT|LVCF_WIDTH; c.pszText=(PWSTR)columns[i]; c.cx=SCALE(widths[i]); ListView_InsertColumn(List,i,&c); }
        Status=CreateWindowExW(0,L"STATIC",L"按路径合并进程；未识别入口不代表不会自启。",WS_CHILD|WS_VISIBLE,0,0,0,0,w,NULL,Module,NULL);
        HFONT font=(HFONT)InvokeMain(15,NULL,NULL);
        if (!font) font=(HFONT)GetStockObject(DEFAULT_GUI_FONT);
        for (int i=0;i<8;i++) SendMessageW(Buttons[i],WM_SETFONT,(WPARAM)font,TRUE);
        SendMessageW(List,WM_SETFONT,(WPARAM)font,TRUE); SendMessageW(Status,WM_SETFONT,(WPARAM)font,TRUE);
        return 0;
    }
    case WM_SIZE: Layout(w); return 0;
    case WM_TIMER: if (wp==1) FinishWorker(); return 0;
    case WM_COMMAND:
        switch (LOWORD(wp))
        {
        case ID_REFRESH: StartWorker(FALSE,FALSE); break;
        case ID_ADMIN: StartWorker(FALSE,TRUE); break;
        case ID_ALL: for (int i=0;i<RowCount;i++) ListView_SetCheckState(List,i,!Protected(i)); break;
        case ID_NONE: for (int i=0;i<RowCount;i++) ListView_SetCheckState(List,i,FALSE); break;
        case ID_DISABLE: Apply(L"disable"); break;
        case ID_CLOSE: Apply(L"close"); break;
        case ID_STARTUP: Apply(L"startup"); break;
        case ID_REPORT:
        {
            WCHAR file[4096]; _snwprintf_s(file,4096,_TRUNCATE,L"%ls\\outputs\\third-party\\第三方程序名单.csv",Root);
            ShellExecuteW(w,L"open",file,NULL,NULL,SW_SHOWNORMAL); break;
        }
        } return 0;
    case WM_NOTIFY:
    {
        NMHDR *header=(NMHDR *)lp;
        if (header->hwndFrom==List && header->code==LVN_ITEMCHANGING)
        {
            NMLISTVIEW *change=(NMLISTVIEW *)lp;
            if ((change->uChanged&LVIF_STATE) && (change->uNewState&LVIS_STATEIMAGEMASK)==INDEXTOSTATEIMAGEMASK(2) && Protected(change->iItem)) return TRUE;
        }
        return 0;
    }
    case WM_DESTROY:
        Destroying=TRUE; KillTimer(w,1); if (Worker) { CloseHandle(Worker); Worker=NULL; } ClearRows(); Panel=NULL; return 0;
    }
    return DefWindowProcW(w,msg,wp,lp);
}
static BOOLEAN NTAPI PageCallback(PAGE *page,ULONG msg,PVOID p1,PVOID p2)
{
    (void)page;
    if (msg==2)
    {
        WNDCLASSEXW wc={0}; wc.cbSize=sizeof(wc); wc.lpfnWndProc=WindowProc; wc.hInstance=Module;
        wc.lpszClassName=L"Local.ThirdPartyManager.Panel"; wc.hCursor=LoadCursorW(NULL,IDC_ARROW); wc.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);
        RegisterClassExW(&wc);
        Dpi=GetDpiForWindow((HWND)p2); if (!Dpi) Dpi=96;
        HWND panel=CreateWindowExW(0,wc.lpszClassName,L"第三方",WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,0,0,0,0,(HWND)p2,NULL,Module,NULL);
        *(HWND *)p1=panel; if (panel) StartWorker(FALSE,FALSE); return panel!=NULL;
    }
    if (msg==8 && Panel) { SendMessageW(List,WM_SETFONT,(WPARAM)p1,TRUE); return TRUE; }
    if (msg==10 && Panel) { Dpi=GetDpiForWindow(Panel); Layout(Panel); return TRUE; }
    return FALSE;
}
static VOID CALLBACK CreatePage(HWND w,UINT m,UINT_PTR id,DWORD time)
{
    (void)w; (void)m; (void)time; KillTimer(NULL,id); CreateTimer=0;
    if (!Page && !Destroying)
    {
        PAGE template={0}; template.Name.Length=sizeof(L"第三方")-sizeof(WCHAR); template.Name.Buffer=L"第三方"; template.Callback=PageCallback;
        Page=CreateTabPage(&template);
    }
}
static VOID NTAPI MainShowing(PVOID p,PVOID context)
{
    (void)p; (void)context;
    // Defer until all built-in plugins have added Disk/Firewall/Devices.
    if (!Page && !CreateTimer) CreateTimer=SetTimer(NULL,0,1,CreatePage);
}
static BOOL HostVersionMatches(void)
{
    WCHAR path[4096]; DWORD ignored=0,size; PVOID data; VS_FIXEDFILEINFO *v; UINT len; BOOL valid=FALSE;
    if (!GetModuleFileNameW(NULL,path,4096)) return FALSE;
    size=GetFileVersionInfoSizeW(path,&ignored); if (!size || !(data=malloc(size))) return FALSE;
    if (GetFileVersionInfoW(path,0,size,data) && VerQueryValueW(data,L"\\",(PVOID *)&v,&len) && len>=sizeof(*v)) valid=v->dwFileVersionMS==MAKELONG(0,4) && v->dwFileVersionLS==MAKELONG(138,26241);
    free(data); return valid;
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID reserved)
{
    (void)reserved;
    if (reason==DLL_PROCESS_ATTACH)
    {
        HMODULE host=GetModuleHandleW(NULL); ZH_PLUGIN_INFORMATION *info=NULL;
        REGISTER_PLUGIN registerPlugin; GET_CALLBACK getCallback; REGISTER_CALLBACK registerCallback;
        union { FARPROC raw; REGISTER_PLUGIN registration; GET_CALLBACK get; REGISTER_CALLBACK callback; INVOKE_MAIN main; PVOID (NTAPI *create)(PVOID); } symbol;
        if (!HostVersionMatches()) return FALSE;
        Module=instance; GetModuleFileNameW(instance,Root,4096);
        WCHAR *last=wcsrchr(Root,L'\\'); if (!last) return FALSE; *last=0;
        last=wcsrchr(Root,L'\\'); if (!last) return FALSE; *last=0;
        // x86 shares the same backend and reports with the x64 portable copy.
        last=wcsrchr(Root,L'\\'); if (last && !_wcsicmp(last+1,L"x86")) *last=0;
        _snwprintf_s(Session,80,_TRUNCATE,L"%lu-%llu",GetCurrentProcessId(),GetTickCount64());
        _snwprintf_s(Base,4096,_TRUNCATE,L"%ls\\work\\third-party\\%ls",Root,Session);
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHREGISTERPLUGINBYNAME)); registerPlugin=symbol.registration;
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHGETGENERALCALLBACK)); getCallback=symbol.get;
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHREGISTERCALLBACK)); registerCallback=symbol.callback;
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(ZH_EXPORT_PHPLUGININVOKEWINDOWCALLBACK)); InvokeMain=symbol.main;
        // Direct API is implemented; main-window callback 19 is a no-op in this release.
        symbol.raw=GetProcAddress(host,MAKEINTRESOURCEA(1198)); CreateTabPage=symbol.create;
        if (!registerPlugin || !getCallback || !registerCallback || !InvokeMain || !CreateTabPage) return FALSE;
        ZH_STRINGREF name={sizeof(L"Local.ThirdPartyManager")-sizeof(WCHAR),L"Local.ThirdPartyManager"};
        if (!registerPlugin(&name,instance,&info) || !info) return FALSE;
        info->DisplayName=L"第三方程序管理"; info->Author=L"Local customization";
        info->Description=L"第三方程序名单与勾选项目的关闭、自启动禁用及恢复记录。";
        registerCallback(getCallback(0),MainShowing,NULL,&Registration);
    }
    return TRUE;
}
