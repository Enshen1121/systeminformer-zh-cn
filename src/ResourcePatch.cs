// Copyright (c) 2026 Enshen1121. MIT License.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace SiZh
{
    public sealed class DialogResource
    {
        public ushort Type, Name, Language;
        public string TextName;
        public byte[] Data;
    }
    public static class ResourcePatch
    {
        public static List<DialogResource> Read(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0 || bytes.Length > 33554432) throw new InvalidDataException("Invalid resource size");
            var result = new List<DialogResource>();
            var seen = new HashSet<string>();
            long pos = 0;
            while (pos < bytes.Length)
            {
                if (bytes.Length - pos < 32) throw new InvalidDataException("Truncated resource header");
                int p = checked((int)pos);
                uint size = BitConverter.ToUInt32(bytes, p);
                uint header = BitConverter.ToUInt32(bytes, p + 4);
                if (header < 32 || header > 4096 || (header & 3) != 0 || pos + header + size > bytes.Length) throw new InvalidDataException("Invalid resource bounds/header");
                if (BitConverter.ToUInt16(bytes, p + 8) != 65535) throw new InvalidDataException("Only numeric resource types are supported");
                ushort type = BitConverter.ToUInt16(bytes, p + 10);
                ushort name = 0; string textName = null;
                int cursor = p + 12;
                if (BitConverter.ToUInt16(bytes, cursor) == 65535) { name = BitConverter.ToUInt16(bytes, cursor + 2); cursor += 4; }
                else
                {
                    var chars = new List<char>();
                    for (;;)
                    {
                        if (cursor + 2 > p + header - 16 || chars.Count > 256) throw new InvalidDataException("Invalid named resource");
                        char c = (char)BitConverter.ToUInt16(bytes, cursor); cursor += 2;
                        if (c == 0) break; chars.Add(c);
                    }
                    if (chars.Count == 0) throw new InvalidDataException("Empty resource name");
                    textName = new string(chars.ToArray());
                }
                cursor = (cursor + 3) & ~3;
                if (cursor + 16 != p + header) throw new InvalidDataException("Invalid resource metadata");
                ushort lang = BitConverter.ToUInt16(bytes, cursor + 6);
                if (size == 0)
                {
                    if (p != 0 || type != 0 || name != 0 || textName != null) throw new InvalidDataException("Unexpected empty resource");
                }
                else
                {
                    if (type != 5 || size > 1048576 || result.Count >= 4096) throw new InvalidDataException("Only bounded DIALOG resources may be applied");
                    if (!seen.Add((textName == null ? "#" + name : "s:" + textName) + ":" + lang)) throw new InvalidDataException("Duplicate resource identifier");
                    byte[] data = new byte[checked((int)size)];
                    Buffer.BlockCopy(bytes, checked(p + (int)header), data, 0, data.Length);
                    result.Add(new DialogResource { Type = type, Name = name, TextName = textName, Language = lang, Data = data });
                }
                pos = (pos + header + size + 3) & ~3L;
                if (pos > bytes.Length) throw new InvalidDataException("Truncated resource padding");
            }
            if (result.Count == 0) throw new InvalidDataException("No DIALOG resources");
            return result;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr BeginUpdateResourceW(string file, bool deleteExisting);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool UpdateResourceW(IntPtr handle, IntPtr type, IntPtr name, ushort language, byte[] data, uint count);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool EndUpdateResourceW(IntPtr handle, bool discard);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryExW(string file, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindResourceExW(IntPtr module, IntPtr type, IntPtr name, ushort language);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint SizeofResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr resource);
        [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
        public static void Apply(string file, byte[] resourceBytes)
        {
            var resources = Read(resourceBytes);
            IntPtr handle = BeginUpdateResourceW(Path.GetFullPath(file), false);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                foreach (var r in resources)
                {
                    IntPtr name = r.TextName == null ? new IntPtr(r.Name) : Marshal.StringToHGlobalUni(r.TextName);
                    try { if (!UpdateResourceW(handle, new IntPtr(r.Type), name, r.Language, r.Data, (uint)r.Data.Length)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
                    finally { if (r.TextName != null) Marshal.FreeHGlobal(name); }
                }
                bool ok = EndUpdateResourceW(handle, false);
                handle = IntPtr.Zero;
                if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { if (handle != IntPtr.Zero) EndUpdateResourceW(handle, true); }
            Verify(file, resourceBytes);
        }
        public static void Verify(string file, byte[] resourceBytes)
        {
            IntPtr module = LoadLibraryExW(Path.GetFullPath(file), IntPtr.Zero, 0x22);
            if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                foreach (var r in Read(resourceBytes))
                {
                    IntPtr name = r.TextName == null ? new IntPtr(r.Name) : Marshal.StringToHGlobalUni(r.TextName);
                    IntPtr resource;
                    try { resource = FindResourceExW(module, new IntPtr(r.Type), name, r.Language); }
                    finally { if (r.TextName != null) Marshal.FreeHGlobal(name); }
                    if (resource == IntPtr.Zero || SizeofResource(module, resource) != r.Data.Length) throw new InvalidDataException("Resource verification failed");
                    IntPtr data = LockResource(LoadResource(module, resource));
                    if (data == IntPtr.Zero) throw new InvalidDataException("Resource unavailable");
                    byte[] actual = new byte[r.Data.Length]; Marshal.Copy(data, actual, 0, actual.Length);
                    for (int i = 0; i < actual.Length; i++) if (actual[i] != r.Data[i]) throw new InvalidDataException("Resource data differs");
                }
            }
            finally { FreeLibrary(module); }
        }
    }
}
