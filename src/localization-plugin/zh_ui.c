#include "zh_ui.h"
#include "zh_dictionary.h"

static PVOID volatile MainWindow;
static PVOID volatile OptionsWindow;

static LRESULT CALLBACK OptionsSubclass(HWND window,UINT message,WPARAM wp,LPARAM lp,UINT_PTR id,DWORD_PTR data)
{
    (void)data;
    if (message==WM_NCDESTROY)
    {
        InterlockedCompareExchangePointer(&OptionsWindow,NULL,window);
        RemoveWindowSubclass(window,OptionsSubclass,id);
    }
    return DefSubclassProc(window,message,wp,lp);
}

void ZhSetOptionsWindow(HWND window)
{
    InterlockedExchangePointer(&OptionsWindow,window);
    if (window) SetWindowSubclass(window,OptionsSubclass,1,0);
}

static BOOL IsOptionsControl(HWND window,int id)
{
    HWND options=(HWND)InterlockedCompareExchangePointer(&OptionsWindow,NULL,NULL);
    return options && GetDlgCtrlID(window)==id && IsChild(options,window);
}

void ZhSetMainWindow(HWND window) { InterlockedExchangePointer(&MainWindow,window); }
BOOL ZhIsMainWindow(HWND window) { return window && window == InterlockedCompareExchangePointer(&MainWindow,NULL,NULL); }

static BOOL IsMainTab(HWND window)
{
    HWND parent=GetParent(window);
    if (!ZhIsMainWindow(parent)) return FALSE;
    // The matching host creates exactly one direct child PhTabNew strip.
    // Refuse the raw page-prefix fallback if an extension adds another one.
    return FindWindowExW(parent,NULL,L"PhTabNew",NULL)==window &&
           !FindWindowExW(parent,window,L"PhTabNew",NULL);
}

static PCWSTR LocalizedStatusText(PCWSTR source,PWSTR output,size_t capacity)
{
    static const ZH_PAIR prefixes[]={
        {L"CPU usage: ",L"CPU 使用率："},
        {L"Physical memory: ",L"物理内存："},
        {L"Free memory: ",L"可用内存："},
    };
    if (!source) return source;
    for (size_t p=0;p<sizeof(prefixes)/sizeof(prefixes[0]);p++)
    {
        size_t length=wcslen(prefixes[p].english);
        if (wcsncmp(source,prefixes[p].english,length)) continue;
        if (_snwprintf_s(output,capacity,_TRUNCATE,L"%ls%ls",prefixes[p].chinese,source+length)>=0) return output;
        break;
    }
    return source;
}

static LRESULT CALLBACK StatusSubclass(HWND window,UINT message,WPARAM wparam,LPARAM lparam,UINT_PTR id,DWORD_PTR data)
{
    (void)data;
    if (message==SB_SETTEXTW && !(wparam&SBT_OWNERDRAW))
    {
        WCHAR localized[4096];
        PCWSTR text=LocalizedStatusText((PCWSTR)lparam,localized,4096);
        return DefSubclassProc(window,message,wparam,(LPARAM)text);
    }
    if (message==WM_NCDESTROY) RemoveWindowSubclass(window,StatusSubclass,id);
    return DefSubclassProc(window,message,wparam,lparam);
}

PCWSTR ZhLookup(PCWSTR text)
{
    size_t low = 0, high = sizeof(ZhDictionary) / sizeof(ZhDictionary[0]);
    if (!text) return NULL;
    while (low < high)
    {
        size_t middle = low + (high - low) / 2;
        int comparison = wcscmp(text, ZhDictionary[middle].english);
        if (!comparison) return ZhDictionary[middle].chinese;
        if (comparison < 0) high = middle; else low = middle + 1;
    }
    return text;
}

ULONG ZhTranslateMenu(ZH_MENU_ITEM *menu)
{
    ULONG count = 0;
    PCWSTR translated;
    if (!menu) return 0;
    // Owned text uses the host's allocator. Leave it untouched rather than
    // changing ownership or handing the host a pointer into this DLL to free.
    if (menu->Text && !(menu->Flags & ZH_MENU_TEXT_OWNED))
    {
        translated = ZhLookup(menu->Text);
        if (translated != menu->Text) { menu->Text = (PWSTR)translated; count++; }
    }
    if (menu->Items)
        for (ULONG i = 0; i < menu->Items->Count; i++)
            count += ZhTranslateMenu(menu->Items->Items[i]);
    return count;
}

ULONG ZhTranslateNativeMenu(HMENU menu)
{
    ULONG count = 0;
    int length = GetMenuItemCount(menu);
    WCHAR text[4096];
    for (int i = 0; i < length; i++)
    {
        MENUITEMINFOW item = { 0 };
        PCWSTR translated;
        item.cbSize = sizeof(item);
        item.fMask = MIIM_STRING | MIIM_SUBMENU;
        item.dwTypeData = text; item.cch = 4096;
        if (!GetMenuItemInfoW(menu, i, TRUE, &item)) continue;
        text[4095] = 0;
        translated = ZhLookup(text);
        if (translated != text)
        {
            MENUITEMINFOW update = { 0 };
            update.cbSize = sizeof(update); update.fMask = MIIM_STRING;
            update.dwTypeData = (PWSTR)translated;
            if (SetMenuItemInfoW(menu, i, TRUE, &update)) count++;
        }
        if (item.hSubMenu) count += ZhTranslateNativeMenu(item.hSubMenu);
    }
    return count;
}

ULONG ZhTranslateControl(HWND window)
{
    WCHAR className[80], text[4096];
    PCWSTR translated;
    ULONG count = 0;
    GetClassNameW(window, className, 80);
    if (!_wcsicmp(className,L"Button") || !_wcsicmp(className,L"Static") ||
        !_wcsicmp(className,L"SysLink") || !_wcsicmp(className,L"#32770"))
    {
        if (GetWindowTextW(window,text,4096) > 0)
        {
            translated = ZhLookup(text);
            if (translated != text && SetWindowTextW(window,translated)) count++;
        }
    }
    else if (!_wcsicmp(className,WC_TABCONTROLW))
    {
        int length = (int)SendMessageW(window,TCM_GETITEMCOUNT,0,0);
        for (int i = 0; i < length; i++)
        {
            TCITEMW item = { 0 };
            item.mask = TCIF_TEXT; item.pszText = text; item.cchTextMax = 4096;
            if (!SendMessageW(window,TCM_GETITEMW,i,(LPARAM)&item)) continue;
            text[4095] = 0; translated = ZhLookup(text);
            if (translated != text)
            {
                item.pszText = (PWSTR)translated;
                if (SendMessageW(window,TCM_SETITEMW,i,(LPARAM)&item)) count++;
            }
        }
    }
    else if (!_wcsicmp(className,L"PhTabNew"))
    {
        int length = (int)SendMessageW(window,ZH_TAB_COUNT,0,0);
        for (int i = 0; i < length; i++)
        {
            ZH_STRINGREF value = { 0 };
            WCHAR property[64];
            ZH_STRINGREF *page = NULL;
            SendMessageW(window,ZH_TAB_GETTEXT,i,(LPARAM)&value);
            // GETITEMTEXT is declared but not implemented in this exact host.
            // The main strip's item parameter is PH_MAIN_TAB_PAGE, whose
            // public prefix is Name. Read that identifier without changing it.
            if (!value.Buffer && IsMainTab(window))
            {
                page=(ZH_STRINGREF *)SendMessageW(window,ZH_TAB_FIRST+9,i,0);
                if (page) value=*page;
                _snwprintf_s(property,64,_TRUNCATE,L"ZH.MainTab.%d",i);
                if (page && GetPropW(window,property)==(HANDLE)page) continue;
            }
            if (!value.Buffer || value.Length >= sizeof(text)) continue;
            memcpy(text,value.Buffer,value.Length); text[value.Length / sizeof(WCHAR)] = 0;
            translated = ZhLookup(text);
            if (translated != text && SendMessageW(window,ZH_TAB_SETTEXT,i,(LPARAM)translated))
            {
                count++;
                if (page) SetPropW(window,property,(HANDLE)page);
            }
        }
    }
    else if (!_wcsicmp(className,L"PhTreeNew"))
    {
        LRESULT maximum = SendMessageW(window,ZH_TN_GETMAXID,0,0);
        if (maximum < 0 || maximum > 4096) return 0;
        for (ULONG id = 0; id <= (ULONG)maximum; id++)
        {
            ZH_TREE_COLUMN column = { 0 };
            if (!SendMessageW(window,ZH_TN_GETCOLUMN,id,(LPARAM)&column) || !column.Text) continue;
            translated = ZhLookup(column.Text);
            if (translated != column.Text)
            {
                column.Text = translated;
                if (SendMessageW(window,ZH_TN_SETCOLUMN,ZH_TN_COLUMN_TEXT,(LPARAM)&column)) count++;
            }
        }
    }
    else if (!_wcsicmp(className,WC_TREEVIEWW) && IsOptionsControl(window,1393))
    {
        HTREEITEM current=TreeView_GetRoot(window);
        for (int visited=0;current && visited<4096;visited++)
        {
            TVITEMW item={0}; HTREEITEM next;
            item.mask=TVIF_TEXT; item.hItem=current; item.pszText=text; item.cchTextMax=4096;
            if (SendMessageW(window,TVM_GETITEMW,0,(LPARAM)&item))
            {
                text[4095]=0; translated=ZhLookup(text);
                if (translated!=text) { item.pszText=(PWSTR)translated; if (SendMessageW(window,TVM_SETITEMW,0,(LPARAM)&item)) count++; }
            }
            next=TreeView_GetChild(window,current);
            if (next) { current=next; continue; }
            while (current && !(next=TreeView_GetNextSibling(window,current))) current=TreeView_GetParent(window,current);
            current=next;
        }
    }
    else if (!_wcsicmp(className,WC_LISTVIEWW) && IsOptionsControl(window,1399) &&
             (ListView_GetExtendedListViewStyle(window)&LVS_EX_CHECKBOXES))
    {
        int length=ListView_GetItemCount(window);
        for (int i=0;i<length && i<4096;i++)
        {
            LVITEMW item={0}; item.mask=LVIF_TEXT; item.iItem=i; item.pszText=text; item.cchTextMax=4096;
            if (!SendMessageW(window,LVM_GETITEMW,0,(LPARAM)&item)) continue;
            text[4095]=0; translated=ZhLookup(text);
            if (translated!=text) { item.pszText=(PWSTR)translated; if (SendMessageW(window,LVM_SETITEMW,0,(LPARAM)&item)) count++; }
        }
    }
    else if (!_wcsicmp(className,TOOLBARCLASSNAMEW))
    {
        int length=(int)SendMessageW(window,TB_BUTTONCOUNT,0,0);
        for (int i=0;i<length;i++)
        {
            TBBUTTON button={0};
            TBBUTTONINFOW update={0};
            LRESULT size;
            if (!SendMessageW(window,TB_GETBUTTON,i,(LPARAM)&button) || (button.fsStyle & BTNS_SEP)) continue;
            size=SendMessageW(window,TB_GETBUTTONTEXTW,button.idCommand,0);
            if (size<=0 || size>=4096) continue;
            SendMessageW(window,TB_GETBUTTONTEXTW,button.idCommand,(LPARAM)text);
            text[4095]=0; translated=ZhLookup(text);
            if (translated!=text)
            {
                update.cbSize=sizeof(update); update.dwMask=TBIF_TEXT; update.pszText=(PWSTR)translated;
                if (SendMessageW(window,TB_SETBUTTONINFOW,button.idCommand,(LPARAM)&update)) count++;
            }
        }
    }
    else if (!_wcsicmp(className,STATUSCLASSNAMEW))
    {
        int length=(int)SendMessageW(window,SB_GETPARTS,0,0);
        SetWindowSubclass(window,StatusSubclass,1,0);
        for (int i=0;i<length;i++)
        {
            LRESULT info=SendMessageW(window,SB_GETTEXTLENGTHW,i,0);
            WCHAR localized[4096];
            if (HIWORD(info)&SBT_OWNERDRAW || LOWORD(info)>=4096) continue;
            SendMessageW(window,SB_GETTEXTW,i,(LPARAM)text); text[4095]=0;
            translated=LocalizedStatusText(text,localized,4096);
            if (translated!=text && SendMessageW(window,SB_SETTEXTW,i|HIWORD(info),(LPARAM)translated)) count++;
        }
    }
    else if (!_wcsicmp(className,WC_HEADERW))
    {
        int length = (int)SendMessageW(window,HDM_GETITEMCOUNT,0,0);
        for (int i = 0; i < length; i++)
        {
            HDITEMW item = { 0 };
            item.mask = HDI_TEXT; item.pszText = text; item.cchTextMax = 4096;
            if (!SendMessageW(window,HDM_GETITEMW,i,(LPARAM)&item)) continue;
            text[4095] = 0; translated = ZhLookup(text);
            if (translated != text)
            {
                item.pszText = (PWSTR)translated;
                if (SendMessageW(window,HDM_SETITEMW,i,(LPARAM)&item)) count++;
            }
        }
    }
    return count;
}
