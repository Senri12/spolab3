using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

internal static class Program
{
    private const string DebugSectionName = "simplelang.debug.json";
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0)
            {
                PrintUsage();
                return 1;
            }

            var command = args[0].Trim().ToLowerInvariant();
            var options = CliOptions.Parse(args.Skip(1).ToArray());

            return command switch
            {
                "embed" => RunEmbed(options),
                "inspect" => RunInspect(options),
                _ => Fail($"Unknown command '{args[0]}'.")
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }

    private static int RunEmbed(CliOptions options)
    {
        var binaryPath = options.RequirePath("binary");
        var asmPath = options.RequirePath("asm");
        var symPath = options.RequirePath("sym");
        var sectionName = options.Get("section-name", DebugSectionName);

        var binary = PtptbBinary.Load(binaryPath);
        var asmMap = AsmDebugMap.Load(asmPath);
        var symModel = SymModel.Load(symPath);
        var sources = SourceResolver.LoadSources(asmMap.SourceFiles, asmPath);

        var functions = symModel.Functions
            .Select(function =>
            {
                var firstSegment = asmMap.Segments.FirstOrDefault(segment =>
                    string.Equals(segment.FunctionName, function.Name, StringComparison.Ordinal));
                function.SourceFileIndex = firstSegment?.SourceFileIndex ?? -1;
                function.SourceLine = firstSegment?.Line ?? 0;
                return function;
            })
            .OrderBy(function => function.StartAddress)
            .ToList();

        var metadata = new DebugMetadata
        {
            Format = "simplelang-debug-v1",
            InstructionSizeBytes = asmMap.InstructionSizeBytes,
            PreferredCodeBank = binary.GetPreferredCodeBank(),
            SourceFiles = sources,
            Segments = asmMap.Segments.OrderBy(segment => segment.StartAddress).ToList(),
            Functions = functions,
            Types = symModel.Types.OrderBy(type => type.Name, StringComparer.Ordinal).ToList()
        };

        var jsonBytes = JsonSerializer.SerializeToUtf8Bytes(metadata, JsonOptions);
        binary.UpsertCustomSection(sectionName, jsonBytes);
        binary.Save(binaryPath);

        Console.WriteLine($"Embedded {metadata.Functions.Count} functions, {metadata.Segments.Count} source segments, {metadata.SourceFiles.Count} source files into {binaryPath}");
        return 0;
    }

    private static int RunInspect(CliOptions options)
    {
        var binaryPath = options.RequirePath("binary");
        var definitionPath = options.RequirePath("definition");
        var ptptb = PtptbBinary.Load(binaryPath);
        var sectionName = options.Get("section-name", DebugSectionName);
        var sectionBytes = ptptb.GetCustomSection(sectionName);
        DebugMetadata metadata;
        if (sectionBytes is null)
        {
            Console.WriteLine($"[warn] Debug section '{sectionName}' not found — using empty metadata (raw ASM mode).");
            metadata = new DebugMetadata
            {
                Format = "simplelang-debug-v1",
                InstructionSizeBytes = 8,
                PreferredCodeBank = "ram",
                SourceFiles = [],
                Segments = [],
                Functions = [],
                Types = []
            };
        }
        else
        {
            metadata = JsonSerializer.Deserialize<DebugMetadata>(sectionBytes, JsonOptions)
                ?? throw new InvalidOperationException("Failed to deserialize embedded debug metadata.");
        }

        var launch = new DebugLaunchOptions
        {
            ManagerPath = options.GetPath("manager", Path.Combine("tools", "RemoteTasks", "Portable.RemoteTasks.Manager.exe")),
            SslConfig = options.GetPath("sslcfg", Path.Combine("tools", "RemoteTasks", "ssl-cfg.yaml")),
            DefinitionFile = definitionPath,
            BinaryFile = binaryPath,
            ArchName = options.Get("arch", "TacVm13"),
            Login = options.Get("login", "505979"),
            Password = options.Get("password", "9d7a3ade-42cd-4693-85e6-5367bbe31597"),
            CodeBankName = options.Get("code-bank", metadata.PreferredCodeBank ?? "ram"),
            IpRegisterName = options.Get("ip-reg", "ip"),
            FinishMnemonicName = options.Get("finish-mnemonic", "halt"),
            RunMode = ParseRunMode(options.Get("run-mode", "plain")),
            DevicesFile = options.GetOptionalPath("devices"),
            InputFile = options.GetOptionalPath("input-file"),
            StdinRegister = options.Get("stdin-reg", "INPUT"),
            StdoutRegister = options.Get("stdout-reg", "OUTPUT")
        };

        var scriptPath = options.GetOptionalPath("script");

        using var session = new InspectorSession(ptptb, metadata, launch);
        if (scriptPath is not null)
        {
            session.RunScript(scriptPath);
            return 0;
        }

        session.RunInteractive();
        return 0;
    }

    private static DebugRunMode ParseRunMode(string value) =>
        value.Trim().ToLowerInvariant() switch
        {
            "plain" => DebugRunMode.Plain,
            "inputfile" => DebugRunMode.InputFile,
            "withio" => DebugRunMode.WithIo,
            _ => throw new InvalidOperationException($"Unsupported run mode '{value}'. Use plain, inputfile or withio.")
        };

    private static int Fail(string message)
    {
        Console.Error.WriteLine(message);
        PrintUsage();
        return 1;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Usage:");
        Console.WriteLine("  SpoInspector embed --binary <file.ptptb> --asm <file.asm> --sym <file.asm.sym> [--section-name <name>]");
        Console.WriteLine("  SpoInspector inspect --binary <file.ptptb> --definition <file.pdsl> [--manager <exe>] [--sslcfg <yaml>] [--arch <name>]");
        Console.WriteLine("                       [--login <login>] [--password <token>] [--run-mode plain|inputfile|withio]");
        Console.WriteLine("                       [--input-file <stdin.txt>] [--devices <devices.xml>] [--script <commands.txt>]");
    }
}

internal sealed class CliOptions
{
    private readonly Dictionary<string, string> _values = new(StringComparer.OrdinalIgnoreCase);

    public static CliOptions Parse(string[] args)
    {
        var options = new CliOptions();
        for (var i = 0; i < args.Length; i++)
        {
            var current = args[i];
            if (!current.StartsWith("--", StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Unexpected argument '{current}'. Expected --name value.");
            }

            var key = current[2..];
            if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                options._values[key] = "true";
                continue;
            }

            options._values[key] = args[++i];
        }

        return options;
    }

    public string Get(string key, string defaultValue)
        => _values.TryGetValue(key, out var value) ? value : defaultValue;

    public string? GetOptional(string key)
        => _values.TryGetValue(key, out var value) ? value : null;

    public string Require(string key)
        => _values.TryGetValue(key, out var value)
            ? value
            : throw new InvalidOperationException($"Missing required option --{key}.");

    public string RequirePath(string key)
    {
        var path = ResolvePath(Require(key));
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Path not found: {path}");
        }

        return path;
    }

    public string GetPath(string key, string defaultValue)
    {
        var path = ResolvePath(Get(key, defaultValue));
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Path not found: {path}");
        }

        return path;
    }

    public string? GetOptionalPath(string key)
    {
        var value = GetOptional(key);
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var path = ResolvePath(value);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Path not found: {path}");
        }

        return path;
    }

    private static string ResolvePath(string value)
        => Path.GetFullPath(value);
}

internal sealed class PtptbBinary
{
    private readonly byte[] _signatureBytes;

    public PtptbBinary(byte[] signatureBytes)
    {
        _signatureBytes = signatureBytes;
    }

    public int FormatVersion { get; set; }
    public int PlatformNameIndex { get; set; }
    public int PlatformVersion { get; set; }
    public long EntryPoint { get; set; }
    public List<PtptbSection> Sections { get; } = [];
    public List<PtptbSymbol> Symbols { get; } = [];
    public List<PtptbSourceFileEntry> SourceFiles { get; } = [];
    public List<PtptbSourceTextRange> SourceTextRanges { get; } = [];
    public List<PtptbSourceCodePoint> SourceCodePoints { get; } = [];
    public List<byte[]> Blobs { get; } = [];
    public List<string> Strings { get; } = [];

    public static PtptbBinary Load(string path)
    {
        using var stream = File.OpenRead(path);
        using var reader = new BinaryReader(stream, Encoding.UTF8, leaveOpen: false);

        var signatureLength = reader.ReadInt32();
        var signatureBytes = reader.ReadBytes(signatureLength);
        var binary = new PtptbBinary(signatureBytes)
        {
            FormatVersion = reader.ReadInt32(),
            PlatformNameIndex = reader.ReadInt32(),
            PlatformVersion = reader.ReadInt32(),
            EntryPoint = reader.ReadInt64()
        };

        var sectionsCount = reader.ReadInt32();
        var symbolsCount = reader.ReadInt32();
        var sourceFilesCount = reader.ReadInt32();
        var sourceTextRangesCount = reader.ReadInt32();
        var sourceCodePointsCount = reader.ReadInt32();
        var blobsCount = reader.ReadInt32();
        var stringsCount = reader.ReadInt32();

        for (var i = 0; i < sectionsCount; i++)
        {
            binary.Sections.Add(new PtptbSection
            {
                BlobIndex = reader.ReadInt32(),
                BankNameIndex = reader.ReadInt32(),
                StartAddress = reader.ReadInt64(),
                Kind = reader.ReadInt16(),
                CustomSectionNameIndex = reader.ReadInt32(),
                AccessMode = reader.ReadInt16()
            });
        }

        for (var i = 0; i < symbolsCount; i++)
        {
            binary.Symbols.Add(new PtptbSymbol
            {
                SectionIndex = reader.ReadInt32(),
                Address = reader.ReadInt64(),
                NameIndex = reader.ReadInt32()
            });
        }

        for (var i = 0; i < sourceFilesCount; i++)
        {
            binary.SourceFiles.Add(new PtptbSourceFileEntry
            {
                FileNameIndex = reader.ReadInt32(),
                Sha256HashBytesIndex = reader.ReadInt32()
            });
        }

        for (var i = 0; i < sourceTextRangesCount; i++)
        {
            binary.SourceTextRanges.Add(new PtptbSourceTextRange
            {
                SourceFileIndex = reader.ReadInt32(),
                Position = reader.ReadInt32(),
                Length = reader.ReadInt32(),
                Line = reader.ReadInt32(),
                Column = reader.ReadInt32()
            });
        }

        for (var i = 0; i < sourceCodePointsCount; i++)
        {
            binary.SourceCodePoints.Add(new PtptbSourceCodePoint
            {
                Address = reader.ReadInt64(),
                SectionIndex = reader.ReadInt32(),
                SourceOperationRangeIndex = reader.ReadInt32()
            });
        }

        var blobLengths = new int[blobsCount];
        for (var i = 0; i < blobsCount; i++)
        {
            blobLengths[i] = reader.ReadInt32();
        }

        for (var i = 0; i < blobsCount; i++)
        {
            binary.Blobs.Add(reader.ReadBytes(blobLengths[i]));
        }

        for (var i = 0; i < stringsCount; i++)
        {
            var length = reader.ReadInt32();
            var bytes = reader.ReadBytes(length);
            binary.Strings.Add(Encoding.UTF8.GetString(bytes));
        }

        return binary;
    }

    public void Save(string path)
    {
        var tempPath = path + ".tmp";
        using (var stream = File.Create(tempPath))
        using (var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: false))
        {
            writer.Write(_signatureBytes.Length);
            writer.Write(_signatureBytes);
            writer.Write(FormatVersion);
            writer.Write(PlatformNameIndex);
            writer.Write(PlatformVersion);
            writer.Write(EntryPoint);

            writer.Write(Sections.Count);
            writer.Write(Symbols.Count);
            writer.Write(SourceFiles.Count);
            writer.Write(SourceTextRanges.Count);
            writer.Write(SourceCodePoints.Count);
            writer.Write(Blobs.Count);
            writer.Write(Strings.Count);

            foreach (var section in Sections)
            {
                writer.Write(section.BlobIndex);
                writer.Write(section.BankNameIndex);
                writer.Write(section.StartAddress);
                writer.Write(section.Kind);
                writer.Write(section.CustomSectionNameIndex);
                writer.Write(section.AccessMode);
            }

            foreach (var symbol in Symbols)
            {
                writer.Write(symbol.SectionIndex);
                writer.Write(symbol.Address);
                writer.Write(symbol.NameIndex);
            }

            foreach (var sourceFile in SourceFiles)
            {
                writer.Write(sourceFile.FileNameIndex);
                writer.Write(sourceFile.Sha256HashBytesIndex);
            }

            foreach (var range in SourceTextRanges)
            {
                writer.Write(range.SourceFileIndex);
                writer.Write(range.Position);
                writer.Write(range.Length);
                writer.Write(range.Line);
                writer.Write(range.Column);
            }

            foreach (var codePoint in SourceCodePoints)
            {
                writer.Write(codePoint.Address);
                writer.Write(codePoint.SectionIndex);
                writer.Write(codePoint.SourceOperationRangeIndex);
            }

            foreach (var blob in Blobs)
            {
                writer.Write(blob.Length);
            }

            foreach (var blob in Blobs)
            {
                writer.Write(blob);
            }

            foreach (var value in Strings)
            {
                var bytes = Encoding.UTF8.GetBytes(value);
                writer.Write(bytes.Length);
                writer.Write(bytes);
            }
        }

        File.Copy(tempPath, path, overwrite: true);
        File.Delete(tempPath);
    }

    public string? GetPreferredCodeBank()
    {
        foreach (var section in Sections)
        {
            if (section.BlobIndex >= 0 &&
                section.BlobIndex < Blobs.Count &&
                Blobs[section.BlobIndex].Length > 0)
            {
                var bankName = GetString(section.BankNameIndex);
                if (!string.IsNullOrWhiteSpace(bankName))
                {
                    return bankName;
                }
            }
        }

        return null;
    }

    public byte[]? GetCustomSection(string name)
    {
        foreach (var section in Sections)
        {
            if (section.Kind != 0)
            {
                continue;
            }

            var customName = GetString(section.CustomSectionNameIndex);
            if (!string.Equals(customName, name, StringComparison.Ordinal))
            {
                continue;
            }

            if (section.BlobIndex < 0 || section.BlobIndex >= Blobs.Count)
            {
                return null;
            }

            return Blobs[section.BlobIndex];
        }

        return null;
    }

    public void UpsertCustomSection(string name, byte[] data)
    {
        var nameIndex = AddString(name);
        var emptyStringIndex = AddString(string.Empty);
        var blobIndex = Blobs.Count;
        Blobs.Add(data);

        for (var i = 0; i < Sections.Count; i++)
        {
            var section = Sections[i];
            if (section.Kind == 0 &&
                string.Equals(GetString(section.CustomSectionNameIndex), name, StringComparison.Ordinal))
            {
                if (section.BlobIndex >= 0 && section.BlobIndex < Blobs.Count)
                {
                    Blobs[section.BlobIndex] = data;
                }
                else
                {
                    section.BlobIndex = blobIndex;
                }

                section.BankNameIndex = emptyStringIndex;
                section.StartAddress = 0;
                section.CustomSectionNameIndex = nameIndex;
                section.AccessMode = 0;
                Sections[i] = section;
                return;
            }
        }

        Sections.Add(new PtptbSection
        {
            BlobIndex = blobIndex,
            BankNameIndex = emptyStringIndex,
            StartAddress = 0,
            Kind = 0,
            CustomSectionNameIndex = nameIndex,
            AccessMode = 0
        });
    }

    public Dictionary<long, List<string>> BuildAddressLabelMap()
    {
        var result = new Dictionary<long, List<string>>();
        foreach (var symbol in Symbols)
        {
            var name = GetString(symbol.NameIndex);
            if (string.IsNullOrWhiteSpace(name))
            {
                continue;
            }

            if (!result.TryGetValue(symbol.Address, out var names))
            {
                names = [];
                result[symbol.Address] = names;
            }

            names.Add(name);
        }

        return result;
    }

    public string GetString(int index)
        => index >= 0 && index < Strings.Count ? Strings[index] : string.Empty;

    private int AddString(string value)
    {
        for (var i = 0; i < Strings.Count; i++)
        {
            if (string.Equals(Strings[i], value, StringComparison.Ordinal))
            {
                return i;
            }
        }

        Strings.Add(value);
        return Strings.Count - 1;
    }
}

internal struct PtptbSection
{
    public int BlobIndex { get; set; }
    public int BankNameIndex { get; set; }
    public long StartAddress { get; set; }
    public short Kind { get; set; }
    public int CustomSectionNameIndex { get; set; }
    public short AccessMode { get; set; }
}

internal struct PtptbSymbol
{
    public int SectionIndex { get; set; }
    public long Address { get; set; }
    public int NameIndex { get; set; }
}

internal struct PtptbSourceFileEntry
{
    public int FileNameIndex { get; set; }
    public int Sha256HashBytesIndex { get; set; }
}

internal struct PtptbSourceTextRange
{
    public int SourceFileIndex { get; set; }
    public int Position { get; set; }
    public int Length { get; set; }
    public int Line { get; set; }
    public int Column { get; set; }
}

internal struct PtptbSourceCodePoint
{
    public long Address { get; set; }
    public int SectionIndex { get; set; }
    public int SourceOperationRangeIndex { get; set; }
}

internal sealed class AsmDebugMap
{
    public int InstructionSizeBytes { get; init; } = 8;
    public List<SourceFileMetadata> SourceFiles { get; } = [];
    public List<SourceSegmentMetadata> Segments { get; } = [];

    public static AsmDebugMap Load(string asmPath)
    {
        var map = new AsmDebugMap();
        var currentSourceFileIndex = -1;
        var currentLine = 0;
        var currentColumn = 0;
        var currentFunction = string.Empty;
        long currentAddress = 0;

        foreach (var rawLine in File.ReadLines(asmPath))
        {
            var line = rawLine.Trim();
            if (line.StartsWith(";; source-file ", StringComparison.Ordinal))
            {
                var rest = line[";; source-file ".Length..];
                var split = rest.IndexOf(' ');
                if (split <= 0)
                {
                    continue;
                }

                var indexText = rest[..split];
                var path = rest[(split + 1)..].Trim();
                if (int.TryParse(indexText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var index))
                {
                    map.SourceFiles.Add(new SourceFileMetadata
                    {
                        Index = index,
                        Path = path
                    });
                }

                continue;
            }

            if (line.StartsWith("; Function: ", StringComparison.Ordinal))
            {
                currentFunction = line["; Function: ".Length..].Trim();
                currentSourceFileIndex = -1;
                currentLine = 0;
                currentColumn = 0;
                continue;
            }

            if (line.StartsWith(";; runtime:", StringComparison.Ordinal))
            {
                currentFunction = string.Empty;
                currentSourceFileIndex = -1;
                currentLine = 0;
                currentColumn = 0;
                continue;
            }

            if (line.StartsWith(";#src ", StringComparison.Ordinal))
            {
                var parts = line[";#src ".Length..]
                    .Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                if (parts.Length >= 3 &&
                    int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var fileIndex) &&
                    int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var sourceLine) &&
                    int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var sourceColumn))
                {
                    currentSourceFileIndex = fileIndex;
                    currentLine = sourceLine;
                    currentColumn = sourceColumn;
                }

                continue;
            }

            if (!IsInstructionLine(line))
            {
                continue;
            }

            if (currentSourceFileIndex >= 0 && currentLine > 0)
            {
                var existing = map.Segments.LastOrDefault();
                if (existing is not null &&
                    existing.EndAddress == currentAddress &&
                    existing.SourceFileIndex == currentSourceFileIndex &&
                    existing.Line == currentLine &&
                    existing.Column == currentColumn &&
                    string.Equals(existing.FunctionName, currentFunction, StringComparison.Ordinal))
                {
                    existing.EndAddress += map.InstructionSizeBytes;
                }
                else
                {
                    map.Segments.Add(new SourceSegmentMetadata
                    {
                        FunctionName = currentFunction,
                        SourceFileIndex = currentSourceFileIndex,
                        Line = currentLine,
                        Column = currentColumn,
                        StartAddress = currentAddress,
                        EndAddress = currentAddress + map.InstructionSizeBytes
                    });
                }
            }

            currentAddress += map.InstructionSizeBytes;
        }

        map.SourceFiles.Sort((left, right) => left.Index.CompareTo(right.Index));
        return map;
    }

    private static bool IsInstructionLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        if (line.StartsWith(";", StringComparison.Ordinal) ||
            line.StartsWith("[", StringComparison.Ordinal))
        {
            return false;
        }

        if (line.EndsWith(":", StringComparison.Ordinal))
        {
            return false;
        }

        return true;
    }
}

internal sealed class SymModel
{
    public List<FunctionMetadata> Functions { get; } = [];
    public List<TypeMetadata> Types { get; } = [];

    public static SymModel Load(string path)
    {
        var model = new SymModel();
        FunctionMetadata? currentFunction = null;
        TypeMetadata? currentType = null;

        foreach (var rawLine in File.ReadLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0)
            {
                currentFunction = null;
                currentType = null;
                continue;
            }

            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (parts.Length == 0)
            {
                continue;
            }

            if (parts[0] == "type" && parts.Length >= 6)
            {
                currentType = new TypeMetadata
                {
                    Name = parts[1],
                    Size = ParseInt(parts[3]),
                    Base = parts[5]
                };
                model.Types.Add(currentType);
                currentFunction = null;
                continue;
            }

            if (parts[0] == "field" && currentType is not null && parts.Length >= 5)
            {
                currentType.Fields.Add(new FieldMetadata
                {
                    OwnerType = parts[1],
                    Name = parts[2],
                    Offset = ParseInt(parts[3]),
                    TypeName = parts[4]
                });
                continue;
            }

            if (parts[0] == "func" && parts.Length >= 8)
            {
                currentFunction = new FunctionMetadata
                {
                    Name = parts[1],
                    StartAddress = ParseInt(parts[3]),
                    EndAddress = ParseInt(parts[5]),
                    FrameSize = ParseInt(parts[7])
                };
                model.Functions.Add(currentFunction);
                currentType = null;
                continue;
            }

            if ((parts[0] == "arg" || parts[0] == "var") && currentFunction is not null && parts.Length >= 5)
            {
                var variable = new VariableMetadata
                {
                    Name = parts[1],
                    Offset = ParseInt(parts[2]),
                    TypeName = "int",
                    IsArgument = parts[0] == "arg"
                };

                for (var i = 3; i < parts.Length; i++)
                {
                    switch (parts[i])
                    {
                        case "type" when i + 1 < parts.Length:
                            variable.TypeName = parts[++i];
                            break;
                        case "arr" when i + 1 < parts.Length:
                            variable.IsArray = true;
                            variable.ArrayLength = ParseInt(parts[++i]);
                            break;
                        case "obj" when i + 2 < parts.Length:
                            variable.IsObject = true;
                            variable.StorageOffset = ParseInt(parts[++i]);
                            variable.StorageSize = ParseInt(parts[++i]);
                            break;
                    }
                }

                currentFunction.Variables.Add(variable);
            }
        }

        return model;
    }

    private static int ParseInt(string value)
        => int.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture);
}

internal static class SourceResolver
{
    public static List<SourceFileMetadata> LoadSources(IEnumerable<SourceFileMetadata> references, string asmPath)
    {
        var asmDirectory = Path.GetDirectoryName(Path.GetFullPath(asmPath)) ?? Environment.CurrentDirectory;
        var workspaceRoot = Directory.GetCurrentDirectory();
        var result = new List<SourceFileMetadata>();

        foreach (var reference in references.OrderBy(item => item.Index))
        {
            var resolvedPath = ResolvePath(reference.Path, asmDirectory, workspaceRoot);
            var source = new SourceFileMetadata
            {
                Index = reference.Index,
                Path = reference.Path,
                ResolvedPath = resolvedPath
            };

            if (resolvedPath is not null)
            {
                source.Text = File.ReadAllText(resolvedPath);
                source.Sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(resolvedPath)));
            }

            result.Add(source);
        }

        return result;
    }

    private static string? ResolvePath(string path, string asmDirectory, string workspaceRoot)
    {
        var candidates = new List<string>();

        if (Path.IsPathRooted(path))
        {
            candidates.Add(Path.GetFullPath(path));
        }
        else
        {
            candidates.Add(Path.GetFullPath(Path.Combine(asmDirectory, path)));
            candidates.Add(Path.GetFullPath(Path.Combine(workspaceRoot, path)));
        }

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        var fileName = Path.GetFileName(path);
        if (!string.IsNullOrWhiteSpace(fileName))
        {
            var found = Directory.EnumerateFiles(workspaceRoot, fileName, SearchOption.AllDirectories)
                .Take(2)
                .ToArray();
            if (found.Length == 1)
            {
                return Path.GetFullPath(found[0]);
            }
        }

        return null;
    }
}

internal sealed class DebugMetadata
{
    public string Format { get; set; } = string.Empty;
    public int InstructionSizeBytes { get; set; }
    public string? PreferredCodeBank { get; set; }
    public List<SourceFileMetadata> SourceFiles { get; set; } = [];
    public List<SourceSegmentMetadata> Segments { get; set; } = [];
    public List<FunctionMetadata> Functions { get; set; } = [];
    public List<TypeMetadata> Types { get; set; } = [];
}

internal sealed class SourceFileMetadata
{
    public int Index { get; set; }
    public string Path { get; set; } = string.Empty;
    public string? ResolvedPath { get; set; }
    public string? Sha256 { get; set; }
    public string? Text { get; set; }

    public string[] GetLines()
        => (Text ?? string.Empty)
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Split('\n');
}

internal sealed class SourceSegmentMetadata
{
    public string FunctionName { get; set; } = string.Empty;
    public int SourceFileIndex { get; set; }
    public int Line { get; set; }
    public int Column { get; set; }
    public long StartAddress { get; set; }
    public long EndAddress { get; set; }
}

internal sealed class FunctionMetadata
{
    public string Name { get; set; } = string.Empty;
    public int SourceFileIndex { get; set; } = -1;
    public int SourceLine { get; set; }
    public int StartAddress { get; set; }
    public int EndAddress { get; set; }
    public int FrameSize { get; set; }
    public List<VariableMetadata> Variables { get; set; } = [];
}

internal sealed class VariableMetadata
{
    public string Name { get; set; } = string.Empty;
    public string TypeName { get; set; } = "int";
    public int Offset { get; set; }
    public bool IsArgument { get; set; }
    public bool IsObject { get; set; }
    public bool IsArray { get; set; }
    public int ArrayLength { get; set; }
    public int StorageOffset { get; set; }
    public int StorageSize { get; set; }
}

internal sealed class TypeMetadata
{
    public string Name { get; set; } = string.Empty;
    public int Size { get; set; }
    public string Base { get; set; } = string.Empty;
    public List<FieldMetadata> Fields { get; set; } = [];
}

internal sealed class FieldMetadata
{
    public string OwnerType { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int Offset { get; set; }
    public string TypeName { get; set; } = string.Empty;
}

internal enum DebugRunMode
{
    Plain,
    InputFile,
    WithIo
}

internal sealed class DebugLaunchOptions
{
    public string ManagerPath { get; set; } = string.Empty;
    public string? SslConfig { get; set; }
    public string DefinitionFile { get; set; } = string.Empty;
    public string BinaryFile { get; set; } = string.Empty;
    public string ArchName { get; set; } = string.Empty;
    public string Login { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public string CodeBankName { get; set; } = "ram";
    public string IpRegisterName { get; set; } = "ip";
    public string FinishMnemonicName { get; set; } = "halt";
    public DebugRunMode RunMode { get; set; }
    public string? DevicesFile { get; set; }
    public string? InputFile { get; set; }
    public string StdinRegister { get; set; } = "INPUT";
    public string StdoutRegister { get; set; } = "OUTPUT";
}

internal sealed class InspectorSession : IDisposable
{
    private readonly PtptbBinary _ptptb;
    private readonly DebugMetadata _metadata;
    private readonly DebugLaunchOptions _launch;
    private readonly Dictionary<int, SourceFileMetadata> _sourceFiles;
    private readonly List<FunctionMetadata> _functions;
    private readonly List<SourceSegmentMetadata> _segments;
    private readonly Dictionary<string, TypeMetadata> _types;
    private readonly Dictionary<long, List<string>> _labelsByAddress;
    private readonly SortedSet<long> _breakpoints = [];
    private MiDebuggerClient _client;
    private bool _hasStartedExecution;
    private bool _programExited;

    public InspectorSession(PtptbBinary ptptb, DebugMetadata metadata, DebugLaunchOptions launch)
    {
        _ptptb = ptptb;
        _metadata = metadata;
        _launch = launch;
        _sourceFiles = metadata.SourceFiles.ToDictionary(source => source.Index);
        _functions = metadata.Functions.OrderBy(function => function.StartAddress).ToList();
        _segments = metadata.Segments.OrderBy(segment => segment.StartAddress).ToList();
        _types = metadata.Types.ToDictionary(type => type.Name, StringComparer.Ordinal);
        _labelsByAddress = ptptb.BuildAddressLabelMap();
        _client = new MiDebuggerClient(_launch);
        _client.Start();
        _hasStartedExecution = false;
        _programExited = false;
    }

    public void RunInteractive()
    {
        Console.WriteLine("Inspector ready. Type 'help' for commands.");
        while (true)
        {
            Console.Write("(dbg) ");
            var line = Console.ReadLine();
            if (line is null)
            {
                return;
            }

            if (!Execute(line))
            {
                return;
            }
        }
    }

    public void RunScript(string path)
    {
        foreach (var rawLine in File.ReadLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal))
            {
                continue;
            }

            Console.WriteLine($"> {line}");
            if (!Execute(line))
            {
                break;
            }
        }
    }

    public void Dispose()
    {
        _client.Dispose();
    }

    private bool Execute(string line)
    {
        var args = SplitArguments(line);
        if (args.Count == 0)
        {
            return true;
        }

        var command = args[0].ToLowerInvariant();
        switch (command)
        {
            case "help":
                PrintHelp();
                return true;
            case "regs":
                PrintRegisters();
                return true;
            case "mem":
                PrintMemory(args);
                return true;
            case "disas":
            case "dis":
                PrintDisassembly(args);
                return true;
            case "step":
            case "si":
                StepInstructions(args);
                return true;
            case "nextsrc":
            case "ns":
                StepSource();
                return true;
            case "cont":
            case "c":
                ContinueExecution(args);
                return true;
            case "break":
            case "b":
                AddAddressBreakpoint(args);
                return true;
            case "bline":
            case "bl":
                AddLineBreakpoint(args);
                return true;
            case "del":
            case "d":
                DeleteAddressBreakpoint(args);
                return true;
            case "dline":
            case "dl":
                DeleteLineBreakpoint(args);
                return true;
            case "breaks":
                PrintBreakpoints();
                return true;
            case "line":
                PrintLineContext();
                return true;
            case "locals":
                PrintLocals();
                return true;
            case "bt":
                PrintBacktrace();
                return true;
            case "run":
                RunProgram();
                return true;
            case "restart":
                Restart();
                return true;
            case "quit":
            case "q":
            case "exit":
                return false;
            default:
                Console.WriteLine($"Unknown command '{args[0]}'. Type 'help' for available commands.");
                return true;
        }
    }

    private void Restart()
    {
        RecreateClient();
        Console.WriteLine("Debugger session restarted.");
        StartToInitialStop();
    }

    private void RunProgram()
    {
        if (_hasStartedExecution && !_programExited)
        {
            RecreateClient();
        }
        else
        {
            _programExited = false;
        }

        StartToInitialStop();
    }

    private void PrintHelp()
    {
        Console.WriteLine("help                show commands");
        Console.WriteLine("regs                print registers");
        Console.WriteLine("mem [bank] addr n   read n bytes from memory");
        Console.WriteLine("disas [addr] [n]    disassemble n instructions");
        Console.WriteLine("step [n]            execute n instructions");
        Console.WriteLine("nextsrc             execute one source-mapped expression");
        Console.WriteLine("cont [max]          continue by stepping until breakpoint or exit");
        Console.WriteLine("break addr          add address breakpoint");
        Console.WriteLine("bline line          add breakpoint for current source file line");
        Console.WriteLine("del addr            remove address breakpoint");
        Console.WriteLine("dline line          remove all breakpoints for current source file line");
        Console.WriteLine("breaks              list breakpoints");
        Console.WriteLine("line                show current source context");
        Console.WriteLine("locals              show args and locals");
        Console.WriteLine("bt                  show call stack");
        Console.WriteLine("run                 start program and stop on the first source point");
        Console.WriteLine("restart             recreate debugger session and stop again");
        Console.WriteLine("quit                exit inspector");
    }

    private void PrintRegisters()
    {
        var registers = _client.GetRegisters();
        var preferred = new[]
        {
            "ip", "fp", "sp", "cmp_result",
            "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7",
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
            "INPUT", "OUTPUT"
        };

        var printed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in preferred)
        {
            if (registers.TryGetValue(name, out var value))
            {
                Console.WriteLine($"{name,-10} {FormatHex(value)} ({value})");
                printed.Add(name);
            }
        }

        foreach (var pair in registers.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (printed.Contains(pair.Key))
            {
                continue;
            }

            Console.WriteLine($"{pair.Key,-10} {FormatHex(pair.Value)} ({pair.Value})");
        }
    }

    private void PrintMemory(List<string> args)
    {
        if (args.Count < 3)
        {
            Console.WriteLine("usage: mem [bank] <addr> <count>");
            return;
        }

        string bank;
        long address;
        var countIndex = args.Count - 1;
        if (args.Count == 3)
        {
            bank = _launch.CodeBankName;
            address = ParseLong(args[1]);
        }
        else
        {
            bank = args[1];
            address = ParseLong(args[2]);
        }

        var count = ParseInt(args[countIndex]);
        var bytes = _client.ReadMemory(bank, address, count);
        DumpHex(address, bytes);
    }

    private void PrintDisassembly(List<string> args)
    {
        var registers = _client.GetRegisters();
        var address = args.Count >= 2 ? ParseLong(args[1]) : GetRegister(registers, _launch.IpRegisterName);
        var count = args.Count >= 3 ? ParseInt(args[2]) : 8;
        var instructions = _client.Disassemble(address, count * _metadata.InstructionSizeBytes);
        var ip = GetRegister(registers, _launch.IpRegisterName);

        foreach (var instruction in instructions)
        {
            var marker = instruction.Address == ip ? "=>" : "  ";
            var labels = _labelsByAddress.TryGetValue(instruction.Address, out var names)
                ? string.Join(", ", names)
                : string.Empty;
            var segment = FindSegment(instruction.Address);
            var sourceSuffix = segment is null
                ? string.Empty
                : $" [{GetShortSourceName(segment.SourceFileIndex)}:{segment.Line}]";
            if (labels.Length > 0)
            {
                Console.WriteLine($"{marker} {FormatHex(instruction.Address),10}  {instruction.Instruction,-24} ; {labels}{sourceSuffix}");
            }
            else
            {
                Console.WriteLine($"{marker} {FormatHex(instruction.Address),10}  {instruction.Instruction}{sourceSuffix}");
            }
        }
    }

    private void StepInstructions(List<string> args)
    {
        var count = args.Count >= 2 ? ParseInt(args[1]) : 1;
        if (!EnsureExecutionStarted())
        {
            return;
        }

        for (var i = 0; i < count; i++)
        {
            var result = _client.StepInstruction();
            if (HandleExecutionResult(result))
            {
                return;
            }
        }

        PrintStatus();
    }

    private void StepSource()
    {
        if (!EnsureExecutionStarted())
        {
            return;
        }

        var startRegisters = _client.GetRegisters();
        var startIp = GetRegister(startRegisters, _launch.IpRegisterName);
        var startSegment = FindSegment(startIp);
        if (startSegment is null)
        {
            StepInstructions(["step"]);
            return;
        }

        for (var i = 0; i < 10000; i++)
        {
            var result = _client.StepInstruction();
            if (HandleExecutionResult(result, printStatusOnStop: false))
            {
                return;
            }

            var registers = _client.GetRegisters();
            var ip = GetRegister(registers, _launch.IpRegisterName);
            var segment = FindSegment(ip);
            if (segment is null)
            {
                continue;
            }

            if (segment.StartAddress != startSegment.StartAddress ||
                segment.Line != startSegment.Line ||
                segment.Column != startSegment.Column ||
                segment.SourceFileIndex != startSegment.SourceFileIndex)
            {
                PrintStatus(registers);
                return;
            }
        }

        Console.WriteLine("Stopped after 10000 instructions without leaving the current source segment.");
    }

    private void ContinueExecution(List<string> args)
    {
        var maxSteps = args.Count >= 2 ? ParseInt(args[1]) : 100000;
        if (_programExited)
        {
            Console.WriteLine("Program already exited. Use run to restart the session.");
            return;
        }

        if (!_hasStartedExecution)
        {
            var result = _client.Run();
            if (HandleExecutionResult(result))
            {
                return;
            }

            var registersAfterRun = _client.GetRegisters();
            var ipAfterRun = GetRegister(registersAfterRun, _launch.IpRegisterName);
            if (_breakpoints.Contains(ipAfterRun))
            {
                Console.WriteLine($"Hit breakpoint at {FormatHex(ipAfterRun)}.");
                PrintStatus(registersAfterRun);
                return;
            }

            if (_breakpoints.Count == 0)
            {
                PrintStatus(registersAfterRun);
                return;
            }
        }

        var registers = _client.GetRegisters();
        var ip = GetRegister(registers, _launch.IpRegisterName);
        if (_breakpoints.Contains(ip))
        {
            // Step past the breakpoint instruction, then continue normally
            var stepResult = _client.StepInstruction();
            if (HandleExecutionResult(stepResult))
            {
                return;
            }
        }

        var result2 = _client.Continue();
        if (HandleExecutionResult(result2))
        {
            return;
        }

        registers = _client.GetRegisters();
        ip = GetRegister(registers, _launch.IpRegisterName);
        if (_breakpoints.Contains(ip))
        {
            Console.WriteLine($"Hit breakpoint at {FormatHex(ip)}.");
            PrintStatus(registers);
            return;
        }

        Console.WriteLine($"Continue stopped after resume without hitting one of the tracked breakpoints (max hint {maxSteps}).");
        PrintStatus(registers);
    }

    private void AddAddressBreakpoint(List<string> args)
    {
        if (args.Count < 2)
        {
            Console.WriteLine("usage: break <addr>");
            return;
        }

        var address = ParseLong(args[1]);
        _breakpoints.Add(address);
        if (!_client.TryInsertBreakpoint(address))
        {
            Console.WriteLine($"Breakpoint set at {FormatHex(address)} (local emulation only).");
            return;
        }

        Console.WriteLine($"Breakpoint set at {FormatHex(address)}.");
    }

    private void AddLineBreakpoint(List<string> args)
    {
        if (args.Count < 2)
        {
            Console.WriteLine("usage: bline <line>");
            return;
        }

        var line = ParseInt(args[1]);
        var currentRegisters = _client.GetRegisters();
        var currentIp = GetRegister(currentRegisters, _launch.IpRegisterName);
        var currentSegment = FindSegment(currentIp);
        var sourceFileIndex = currentSegment?.SourceFileIndex ?? ResolveSingleSourceFileIndex();
        if (sourceFileIndex < 0)
        {
            Console.WriteLine("Unable to determine the current source file.");
            return;
        }

        var matches = _segments
            .Where(segment => segment.SourceFileIndex == sourceFileIndex && segment.Line == line)
            .Select(segment => segment.StartAddress)
            .Distinct()
            .ToList();
        if (matches.Count == 0)
        {
            Console.WriteLine($"No source-mapped instructions were found for line {line}.");
            return;
        }

        foreach (var address in matches)
        {
            _breakpoints.Add(address);
            _client.TryInsertBreakpoint(address);
        }

        Console.WriteLine($"Added {matches.Count} breakpoint(s) for {GetShortSourceName(sourceFileIndex)}:{line}.");
    }

    private void DeleteAddressBreakpoint(List<string> args)
    {
        if (args.Count < 2)
        {
            Console.WriteLine("usage: del <addr>");
            return;
        }

        var address = ParseLong(args[1]);
        if (_breakpoints.Remove(address))
        {
            _client.TryDeleteBreakpoint(address);
            Console.WriteLine($"Removed breakpoint at {FormatHex(address)}.");
        }
        else
        {
            Console.WriteLine($"Breakpoint {FormatHex(address)} was not set.");
        }
    }

    private void DeleteLineBreakpoint(List<string> args)
    {
        if (args.Count < 2)
        {
            Console.WriteLine("usage: dline <line>");
            return;
        }

        var line = ParseInt(args[1]);
        var currentRegisters = _client.GetRegisters();
        var currentIp = GetRegister(currentRegisters, _launch.IpRegisterName);
        var currentSegment = FindSegment(currentIp);
        var sourceFileIndex = currentSegment?.SourceFileIndex ?? ResolveSingleSourceFileIndex();
        if (sourceFileIndex < 0)
        {
            Console.WriteLine("Unable to determine the current source file.");
            return;
        }

        var toRemove = _segments
            .Where(segment => segment.SourceFileIndex == sourceFileIndex && segment.Line == line)
            .Select(segment => segment.StartAddress)
            .Distinct()
            .ToList();
        var removed = 0;
        foreach (var address in toRemove)
        {
            if (_breakpoints.Remove(address))
            {
                _client.TryDeleteBreakpoint(address);
                removed++;
            }
        }

        Console.WriteLine($"Removed {removed} breakpoint(s) for {GetShortSourceName(sourceFileIndex)}:{line}.");
    }

    private void PrintBreakpoints()
    {
        if (_breakpoints.Count == 0)
        {
            Console.WriteLine("No breakpoints.");
            return;
        }

        foreach (var address in _breakpoints)
        {
            var segment = FindSegment(address);
            if (segment is null)
            {
                Console.WriteLine($"{FormatHex(address)}");
                continue;
            }

            Console.WriteLine($"{FormatHex(address)}  {GetShortSourceName(segment.SourceFileIndex)}:{segment.Line}");
        }
    }

    private void PrintLineContext()
    {
        if (!EnsureRuntimeContext("line"))
        {
            return;
        }

        var registers = _client.GetRegisters();
        var ip = GetRegister(registers, _launch.IpRegisterName);
        var segment = FindSegment(ip);
        if (segment is null)
        {
            Console.WriteLine($"No source mapping for {FormatHex(ip)}.");
            return;
        }

        if (!_sourceFiles.TryGetValue(segment.SourceFileIndex, out var sourceFile) || string.IsNullOrEmpty(sourceFile.Text))
        {
            Console.WriteLine($"{GetShortSourceName(segment.SourceFileIndex)}:{segment.Line}:{segment.Column}");
            return;
        }

        var lines = sourceFile.GetLines();
        var start = Math.Max(1, segment.Line - 2);
        var end = Math.Min(lines.Length, segment.Line + 2);
        Console.WriteLine($"{sourceFile.Path}:{segment.Line}:{segment.Column}");
        for (var lineNumber = start; lineNumber <= end; lineNumber++)
        {
            var marker = lineNumber == segment.Line ? "=>" : "  ";
            var text = lineNumber - 1 < lines.Length ? lines[lineNumber - 1] : string.Empty;
            Console.WriteLine($"{marker} {lineNumber,4} | {text}");
        }
    }

    private void PrintLocals()
    {
        if (!EnsureRuntimeContext("locals"))
        {
            return;
        }

        var registers = _client.GetRegisters();
        var ip = GetRegister(registers, _launch.IpRegisterName);
        var fp = GetRegister(registers, "fp");
        var function = FindFunction(ip);
        if (function is null)
        {
            Console.WriteLine($"No debug locals for {FormatHex(ip)}.");
            return;
        }

        var args = function.Variables.Where(variable => variable.IsArgument).OrderBy(variable => variable.Offset).ToList();
        var locals = function.Variables.Where(variable => !variable.IsArgument).OrderByDescending(variable => variable.Offset).ToList();

        if (args.Count == 0 && locals.Count == 0)
        {
            Console.WriteLine($"Function {function.Name} has no recorded locals.");
            return;
        }

        Console.WriteLine($"Function {function.Name}  fp={FormatHex(fp)}");
        foreach (var variable in args)
        {
            Console.WriteLine($"arg   {FormatVariable(variable, fp)}");
        }

        foreach (var variable in locals)
        {
            Console.WriteLine($"local {FormatVariable(variable, fp)}");
        }
    }

    private void PrintBacktrace()
    {
        if (!EnsureRuntimeContext("bt"))
        {
            return;
        }

        var registers = _client.GetRegisters();
        long ip = GetRegister(registers, _launch.IpRegisterName);
        long fp = GetRegister(registers, "fp");
        var seenFrames = new HashSet<long>();

        for (var depth = 0; depth < 64; depth++)
        {
            var function = FindFunction(ip);
            var segment = FindSegment(ip);
            var functionName = function?.Name ?? ResolveSymbolName(ip) ?? "<unknown>";
            var source = segment is null ? string.Empty : $" {GetShortSourceName(segment.SourceFileIndex)}:{segment.Line}";
            Console.WriteLine($"#{depth} {functionName} at {FormatHex(ip)}{source}");

            if (fp == 0 || !seenFrames.Add(fp))
            {
                return;
            }

            var previousFp = ReadInt32(_launch.CodeBankName, fp);
            var returnAddress = ReadInt32(_launch.CodeBankName, fp + 4);
            if (previousFp == 0 && returnAddress == 0)
            {
                return;
            }

            fp = previousFp;
            ip = returnAddress;
        }
    }

    private void PrintStatus(Dictionary<string, long>? registers = null)
    {
        registers ??= _client.GetRegisters();
        var ip = GetRegister(registers, _launch.IpRegisterName);
        var segment = FindSegment(ip);
        var function = FindFunction(ip);
        if (segment is null)
        {
            Console.WriteLine($"Stopped at {FormatHex(ip)} in {function?.Name ?? ResolveSymbolName(ip) ?? "<unknown>"}.");
            return;
        }

        Console.WriteLine($"Stopped at {FormatHex(ip)} in {function?.Name ?? segment.FunctionName} ({GetShortSourceName(segment.SourceFileIndex)}:{segment.Line}).");
    }

    private string FormatVariable(VariableMetadata variable, long fp)
    {
        var address = fp + variable.Offset;
        if (variable.IsArray)
        {
            var pointer = ReadInt32(_launch.CodeBankName, address);
            if (pointer == 0)
            {
                return $"{variable.Name}: {variable.TypeName}[] = null";
            }

            var previewLength = variable.ArrayLength > 0 ? Math.Min(variable.ArrayLength, 8) : 4;
            var preview = previewLength > 0
                ? ReadWords(_launch.CodeBankName, pointer, previewLength)
                : [];
            var previewText = string.Join(", ", preview.Select(value => FormatScalar(value, variable.TypeName)));
            var suffix = variable.ArrayLength > previewLength ? ", ..." : string.Empty;
            var lengthText = variable.ArrayLength > 0 ? $" len={variable.ArrayLength}" : string.Empty;
            return $"{variable.Name}: {variable.TypeName}[] @{FormatHex(pointer)}{lengthText} [{previewText}{suffix}]";
        }

        if (variable.IsObject)
        {
            var pointer = ReadInt32(_launch.CodeBankName, address);
            if (pointer == 0)
            {
                return $"{variable.Name}: {variable.TypeName} = null";
            }

            return $"{variable.Name}: {variable.TypeName} @{FormatHex(pointer)} {FormatObject(pointer, variable.TypeName, 0)}";
        }

        var scalar = ReadInt32(_launch.CodeBankName, address);
        return $"{variable.Name}: {variable.TypeName} = {FormatScalar(scalar, variable.TypeName)}";
    }

    private string FormatObject(long address, string typeName, int depth)
    {
        if (depth >= 2 || !_types.TryGetValue(typeName, out var type))
        {
            return "{...}";
        }

        var parts = new List<string>();
        foreach (var field in type.Fields.OrderBy(field => field.Offset))
        {
            var fieldAddress = address + field.Offset;
            if (IsArrayType(field.TypeName))
            {
                var pointer = ReadInt32(_launch.CodeBankName, fieldAddress);
                parts.Add($"{field.Name}=@{FormatHex(pointer)}");
                continue;
            }

            if (_types.ContainsKey(field.TypeName))
            {
                var pointer = ReadInt32(_launch.CodeBankName, fieldAddress);
                parts.Add(pointer == 0
                    ? $"{field.Name}=null"
                    : $"{field.Name}=@{FormatHex(pointer)} {FormatObject(pointer, field.TypeName, depth + 1)}");
                continue;
            }

            var value = ReadInt32(_launch.CodeBankName, fieldAddress);
            parts.Add($"{field.Name}={FormatScalar(value, field.TypeName)}");
        }

        return "{" + string.Join(", ", parts) + "}";
    }

    private FunctionMetadata? FindFunction(long address)
    {
        for (var i = _functions.Count - 1; i >= 0; i--)
        {
            var function = _functions[i];
            if (address >= function.StartAddress && address < function.EndAddress)
            {
                return function;
            }
        }

        return null;
    }

    private SourceSegmentMetadata? FindSegment(long address)
    {
        for (var i = _segments.Count - 1; i >= 0; i--)
        {
            var segment = _segments[i];
            if (address >= segment.StartAddress && address < segment.EndAddress)
            {
                return segment;
            }
        }

        return null;
    }

    private string? ResolveSymbolName(long address)
        => _labelsByAddress.TryGetValue(address, out var names) && names.Count > 0 ? names[0] : null;

    private int ResolveSingleSourceFileIndex()
        => _metadata.SourceFiles.Count == 1 ? _metadata.SourceFiles[0].Index : -1;

    private int ReadInt32(string bank, long address)
    {
        var bytes = _client.ReadMemory(bank, address, 4);
        if (bytes.Length < 4)
        {
            return 0;
        }

        return BitConverter.ToInt32(bytes, 0);
    }

    private int[] ReadWords(string bank, long address, int count)
    {
        var bytes = _client.ReadMemory(bank, address, count * 4);
        var result = new List<int>();
        for (var offset = 0; offset + 4 <= bytes.Length; offset += 4)
        {
            result.Add(BitConverter.ToInt32(bytes, offset));
        }

        return result.ToArray();
    }

    private static long GetRegister(Dictionary<string, long> registers, string name)
    {
        if (registers.TryGetValue(name, out var value))
        {
            return value;
        }

        foreach (var pair in registers)
        {
            if (string.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                return pair.Value;
            }
        }

        return 0;
    }

    private static void PrintStreams(MiCommandResult result)
    {
        foreach (var stream in result.Streams)
        {
            if (!string.IsNullOrWhiteSpace(stream))
            {
                Console.WriteLine(stream);
            }
        }
    }

    private string GetShortSourceName(int sourceFileIndex)
    {
        if (_sourceFiles.TryGetValue(sourceFileIndex, out var sourceFile) &&
            !string.IsNullOrWhiteSpace(sourceFile.Path))
        {
            return Path.GetFileName(sourceFile.Path);
        }

        return sourceFileIndex >= 0 ? sourceFileIndex.ToString(CultureInfo.InvariantCulture) : "?";
    }

    private void RecreateClient()
    {
        _client.Dispose();
        _client = new MiDebuggerClient(_launch);
        _client.Start();
        _hasStartedExecution = false;
        _programExited = false;

        foreach (var address in _breakpoints)
        {
            _client.TryInsertBreakpoint(address);
        }
    }

    private bool EnsureExecutionStarted()
    {
        if (_programExited)
        {
            Console.WriteLine("Program already exited. Use run to restart the session.");
            return false;
        }

        if (_hasStartedExecution)
        {
            return true;
        }

        StartToInitialStop();
        return _hasStartedExecution && !_programExited;
    }

    private bool EnsureRuntimeContext(string commandName)
    {
        if (_programExited)
        {
            Console.WriteLine("Program already exited. Use run to restart the session.");
            return false;
        }

        if (_hasStartedExecution)
        {
            return true;
        }

        Console.WriteLine($"Program has not started yet. Use run, step, nextsrc or cont before {commandName}.");
        return false;
    }

    private void StartToInitialStop()
    {
        var tempAddress = _breakpoints.Count == 0 ? ResolveInitialStopAddress() : null;
        var tempInserted = tempAddress.HasValue && _client.TryInsertBreakpoint(tempAddress.Value);
        try
        {
            var result = _client.Run();
            HandleExecutionResult(result);
        }
        finally
        {
            if (tempInserted && tempAddress.HasValue && !_breakpoints.Contains(tempAddress.Value))
            {
                _client.TryDeleteBreakpoint(tempAddress.Value);
            }
        }
    }

    private long? ResolveInitialStopAddress()
    {
        if (_segments.Count > 0)
        {
            return _segments[0].StartAddress;
        }

        if (_functions.Count > 0)
        {
            return _functions[0].StartAddress;
        }

        return _labelsByAddress.Keys.Count > 0 ? _labelsByAddress.Keys.Min() : null;
    }

    private bool HandleExecutionResult(MiCommandResult result, bool printStatusOnStop = true)
    {
        PrintStreams(result);
        if (result.StopReason == "exited-normally")
        {
            _hasStartedExecution = false;
            _programExited = true;
            Console.WriteLine("Program exited.");
            return true;
        }

        _hasStartedExecution = true;
        _programExited = false;
        if (printStatusOnStop)
        {
            PrintStatus();
        }

        return false;
    }

    private static bool IsArrayType(string typeName)
        => typeName.Contains('[', StringComparison.Ordinal) && typeName.Contains(']', StringComparison.Ordinal);

    private static string FormatScalar(int value, string typeName)
    {
        if (string.Equals(typeName, "char", StringComparison.OrdinalIgnoreCase))
        {
            var ch = value is >= 32 and <= 126 ? ((char)value).ToString() : "?";
            return $"'{ch}' ({value})";
        }

        if (string.Equals(typeName, "bool", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(typeName, "boolean", StringComparison.OrdinalIgnoreCase))
        {
            return value == 0 ? "false" : "true";
        }

        return value.ToString(CultureInfo.InvariantCulture);
    }

    private static string FormatHex(long value)
        => "0x" + value.ToString("X", CultureInfo.InvariantCulture);

    private static void DumpHex(long startAddress, byte[] bytes)
    {
        for (var offset = 0; offset < bytes.Length; offset += 16)
        {
            var chunk = bytes.Skip(offset).Take(16).ToArray();
            var hex = string.Join(" ", chunk.Select(value => value.ToString("X2", CultureInfo.InvariantCulture)));
            Console.WriteLine($"{FormatHex(startAddress + offset),10}  {hex}");
        }
    }

    private static int ParseInt(string text)
        => int.Parse(text, NumberStyles.Integer, CultureInfo.InvariantCulture);

    private static long ParseLong(string text)
    {
        var value = text.Trim();
        if (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            return long.Parse(value[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        }

        return long.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture);
    }

    private static List<string> SplitArguments(string line)
    {
        var result = new List<string>();
        if (string.IsNullOrWhiteSpace(line))
        {
            return result;
        }

        var current = new StringBuilder();
        var inQuotes = false;
        for (var i = 0; i < line.Length; i++)
        {
            var ch = line[i];
            if (ch == '"')
            {
                inQuotes = !inQuotes;
                continue;
            }

            if (char.IsWhiteSpace(ch) && !inQuotes)
            {
                if (current.Length > 0)
                {
                    result.Add(current.ToString());
                    current.Clear();
                }

                continue;
            }

            current.Append(ch);
        }

        if (current.Length > 0)
        {
            result.Add(current.ToString());
        }

        return result;
    }
}

internal sealed class MiDebuggerClient : IDisposable
{
    private readonly DebugLaunchOptions _options;
    private readonly BlockingCollection<MiRecord> _records = new(new ConcurrentQueue<MiRecord>());
    private readonly Dictionary<string, int> _registerNameToNumber = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _rawLogLock = new();
    private readonly string? _rawLogPath = Environment.GetEnvironmentVariable("SPO_INSPECTOR_RAW_LOG");
    private Process? _process;
    private Task? _stdoutTask;
    private Task? _stderrTask;
    private int _nextToken;
    private readonly Dictionary<long, string> _breakpointIdsByAddress = new();
    private string? _memoryReadTemplate;

    public MiDebuggerClient(DebugLaunchOptions options)
    {
        _options = options;
    }

    public void Start()
    {
        if (_process is not null)
        {
            return;
        }

        var workingDirectory = ResolveManagerWorkingDirectory();
        var definitionFile = ToManagerTaskPath(_options.DefinitionFile, workingDirectory);
        var binaryFile = ToManagerTaskPath(_options.BinaryFile, workingDirectory);
        var inputFile = string.IsNullOrWhiteSpace(_options.InputFile) ? null : ToManagerTaskPath(_options.InputFile, workingDirectory);
        var devicesFile = string.IsNullOrWhiteSpace(_options.DevicesFile) ? null : ToManagerTaskPath(_options.DevicesFile, workingDirectory);
        var sslConfig = string.IsNullOrWhiteSpace(_options.SslConfig) ? null : ToManagerTaskPath(_options.SslConfig, workingDirectory);
        var startInfo = new ProcessStartInfo
        {
            FileName = _options.ManagerPath,
            WorkingDirectory = workingDirectory,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (!string.IsNullOrWhiteSpace(_options.SslConfig))
        {
            startInfo.ArgumentList.Add("-sslcfg");
            startInfo.ArgumentList.Add(sslConfig!);
        }

        startInfo.ArgumentList.Add("-ul");
        startInfo.ArgumentList.Add(_options.Login);
        startInfo.ArgumentList.Add("-up");
        startInfo.ArgumentList.Add(_options.Password);
        startInfo.ArgumentList.Add("-il");
        startInfo.ArgumentList.Add("-q");
        startInfo.ArgumentList.Add("-w");
        startInfo.ArgumentList.Add("-s");
        startInfo.ArgumentList.Add(GetTaskName());

        switch (_options.RunMode)
        {
            case DebugRunMode.InputFile:
                if (string.IsNullOrWhiteSpace(inputFile))
                {
                    throw new InvalidOperationException("--input-file is required for run-mode inputfile.");
                }

                startInfo.ArgumentList.Add("stdinRegStName");
                startInfo.ArgumentList.Add(_options.StdinRegister);
                startInfo.ArgumentList.Add("stdoutRegStName");
                startInfo.ArgumentList.Add(_options.StdoutRegister);
                startInfo.ArgumentList.Add("inputFile");
                startInfo.ArgumentList.Add(inputFile);
                break;
            case DebugRunMode.WithIo:
                if (string.IsNullOrWhiteSpace(devicesFile))
                {
                    throw new InvalidOperationException("--devices is required for run-mode withio.");
                }

                startInfo.ArgumentList.Add("devices.xml");
                startInfo.ArgumentList.Add(devicesFile);
                break;
        }

        startInfo.ArgumentList.Add("definitionFile");
        startInfo.ArgumentList.Add(definitionFile);
        startInfo.ArgumentList.Add("archName");
        startInfo.ArgumentList.Add(_options.ArchName);
        startInfo.ArgumentList.Add("binaryFileToRun");
        startInfo.ArgumentList.Add(binaryFile);
        startInfo.ArgumentList.Add("codeRamBankName");
        startInfo.ArgumentList.Add(_options.CodeBankName);
        startInfo.ArgumentList.Add("ipRegStorageName");
        startInfo.ArgumentList.Add(_options.IpRegisterName);
        startInfo.ArgumentList.Add("finishMnemonicName");
        startInfo.ArgumentList.Add(_options.FinishMnemonicName);

        _process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Failed to start Portable.RemoteTasks.Manager.exe.");
        _stdoutTask = Task.Run(ReadStdoutAsync);
        _stderrTask = Task.Run(ReadStderrAsync);
        WaitForPrompt(TimeSpan.FromSeconds(30));
    }

    private string ResolveManagerWorkingDirectory()
    {
        var candidates = new[]
        {
            _options.BinaryFile,
            _options.DefinitionFile,
            _options.InputFile,
            _options.DevicesFile,
            _options.SslConfig
        }
        .Where(path => !string.IsNullOrWhiteSpace(path))
        .Select(path => Path.GetDirectoryName(Path.GetFullPath(path!)) ?? Path.GetFullPath(path!))
        .ToList();

        if (candidates.Count == 0)
        {
            return Environment.CurrentDirectory;
        }

        var common = candidates[0];
        foreach (var candidate in candidates.Skip(1))
        {
            common = GetCommonDirectory(common, candidate);
        }

        return string.IsNullOrWhiteSpace(common) ? Environment.CurrentDirectory : common;
    }

    private static string GetCommonDirectory(string left, string right)
    {
        var normalizedRight = Path.GetFullPath(right)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var current = new DirectoryInfo(Path.GetFullPath(left));
        while (current is not null)
        {
            var candidate = current.FullName.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (normalizedRight.Equals(candidate, StringComparison.OrdinalIgnoreCase) ||
                normalizedRight.StartsWith(candidate + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                normalizedRight.StartsWith(candidate + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        return Path.GetPathRoot(Path.GetFullPath(left)) ?? Environment.CurrentDirectory;
    }

    private static string ToManagerTaskPath(string path, string workingDirectory)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
        {
            return path;
        }

        try
        {
            var relative = Path.GetRelativePath(workingDirectory, path);
            if (!Path.IsPathRooted(relative) &&
                !relative.Equals("..", StringComparison.Ordinal) &&
                !relative.StartsWith($"..{Path.DirectorySeparatorChar}", StringComparison.Ordinal) &&
                !relative.StartsWith($"..{Path.AltDirectorySeparatorChar}", StringComparison.Ordinal))
            {
                return relative;
            }
        }
        catch
        {
        }

        return path;
    }

    public Dictionary<string, long> GetRegisters()
    {
        EnsureRegisterNames();
        var result = SendCommand("data-list-register-values x");
        var valuesNode = result.Results.TryGetValue("register-values", out var node)
            ? node
            : throw new InvalidOperationException("MI response did not contain register-values.");
        var dictionary = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in valuesNode.EnumerateList())
        {
            var numberText = item.Get("number").GetConst();
            var valueText = item.Get("value").GetConst();
            if (!int.TryParse(numberText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number))
            {
                continue;
            }

            var value = ParseMiNumber(valueText);
            foreach (var pair in _registerNameToNumber.Where(pair => pair.Value == number))
            {
                dictionary[pair.Key] = value;
            }
        }

        return dictionary;
    }

    public byte[] ReadMemory(string bank, long address, int count)
    {
        EnsureMemoryReadTemplate(bank);
        var command = string.Format(CultureInfo.InvariantCulture, _memoryReadTemplate!, address, count, bank);
        var result = SendCommand(command);
        return ParseMemoryBytes(result.Results);
    }

    public IReadOnlyList<DisassembledInstruction> Disassemble(long startAddress, int byteCount)
    {
        var endAddress = startAddress + byteCount;
        var result = SendCommand($"data-disassemble -s {startAddress} -e {endAddress} -- 0");
        if (!result.Results.TryGetValue("asm_insns", out var node))
        {
            return [];
        }

        var instructions = new List<DisassembledInstruction>();
        foreach (var item in node.EnumerateList())
        {
            instructions.Add(new DisassembledInstruction
            {
                Address = ParseMiNumber(item.Get("address").GetConst()),
                Instruction = item.Get("inst").GetConst()
            });
        }

        return instructions;
    }

    public MiCommandResult StepInstruction()
        => SendExecCommand("exec-next-instruction");

    public MiCommandResult Run()
        => SendExecCommand("exec-run");

    public MiCommandResult Continue()
        => SendExecCommand("exec-continue");

    public bool TryInsertBreakpoint(long address)
    {
        if (_breakpointIdsByAddress.ContainsKey(address))
        {
            return true;
        }

        foreach (var command in EnumerateBreakpointInsertCommands(address))
        {
            try
            {
                var result = SendCommand(command);
                var breakpointId = ExtractBreakpointId(result.Results);
                if (!string.IsNullOrWhiteSpace(breakpointId))
                {
                    _breakpointIdsByAddress[address] = breakpointId;
                    return true;
                }
            }
            catch
            {
            }
        }

        return false;
    }

    public bool TryDeleteBreakpoint(long address)
    {
        if (!_breakpointIdsByAddress.TryGetValue(address, out var breakpointId))
        {
            return false;
        }

        try
        {
            SendCommand($"break-delete {breakpointId}");
            _breakpointIdsByAddress.Remove(address);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        try
        {
            if (_process is not null && !_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(5000);
            }
        }
        catch
        {
        }

        _process?.Dispose();
        _records.Dispose();
    }

    private string GetTaskName()
        => _options.RunMode switch
        {
            DebugRunMode.Plain => "MachineDebugBinary",
            DebugRunMode.InputFile => "MachineDebugBinaryWithInput",
            DebugRunMode.WithIo => "MachineDebugBinaryWithIo",
            _ => throw new InvalidOperationException("Unsupported run mode.")
        };

    private void EnsureRegisterNames()
    {
        if (_registerNameToNumber.Count > 0)
        {
            return;
        }

        var result = SendCommand("data-list-register-names");
        if (!result.Results.TryGetValue("register-names", out var namesNode))
        {
            throw new InvalidOperationException("MI response did not contain register-names.");
        }

        var names = namesNode.EnumerateList().Select(item => item.GetConst()).ToList();
        for (var i = 0; i < names.Count; i++)
        {
            var name = names[i];
            if (!string.IsNullOrWhiteSpace(name) && !_registerNameToNumber.ContainsKey(name))
            {
                _registerNameToNumber[name] = i;
            }
        }
    }

    private void EnsureMemoryReadTemplate(string bank)
    {
        if (_memoryReadTemplate is not null)
        {
            return;
        }

        var candidates = new[]
        {
            "data-read-memory-bytes {0} {1}",
            "data-read-memory-bytes {2} {0} {1}",
            "data-read-memory-bytes -o 0 {0} {1}",
            "data-read-memory-bytes -o 0 {2} {0} {1}",
            "data-read-memory-bytes bank {2} {0} {1}",
            "data-read-memory-bytes {0} {1} bank {2}",
            "data-read-memory-bytes --bank {2} {0} {1}",
            "data-read-memory-bytes -b {2} {0} {1}",
        };

        foreach (var candidate in candidates)
        {
            try
            {
                var result = SendCommand(string.Format(CultureInfo.InvariantCulture, candidate, 0, 4, bank));
                ParseMemoryBytes(result.Results);
                _memoryReadTemplate = candidate;
                return;
            }
            catch
            {
            }
        }

        throw new InvalidOperationException("Unable to determine MI syntax for reading memory.");
    }

    private static byte[] ParseMemoryBytes(Dictionary<string, MiValue> results)
    {
        if (results.TryGetValue("memory", out var memoryNode))
        {
            foreach (var item in memoryNode.EnumerateList())
            {
                if (item.TryGet("contents", out var contentsNode))
                {
                    return ParseHexBytes(contentsNode.GetConst());
                }
            }
        }

        if (results.TryGetValue("contents", out var directContents))
        {
            return ParseHexBytes(directContents.GetConst());
        }

        throw new InvalidOperationException("MI response did not contain readable memory bytes.");
    }

    private MiCommandResult SendCommand(string command)
    {
        var token = Interlocked.Increment(ref _nextToken);
        WriteLine($"{token}-{command}");
        var records = new List<MiRecord>();
        MiRecord? resultRecord = null;

        while (true)
        {
            var record = TakeRecord(TimeSpan.FromSeconds(30));
            if (record.Kind == MiRecordKind.Prompt)
            {
                continue;
            }

            records.Add(record);
            if (record.Kind == MiRecordKind.Result && record.Token == token)
            {
                resultRecord = record;
                break;
            }
        }

        if (resultRecord is null)
        {
            throw new InvalidOperationException($"No MI result was received for command '{command}'.");
        }

        var result = new MiCommandResult(resultRecord, records);
        if (string.Equals(result.ResultClass, "error", StringComparison.Ordinal))
        {
            var message = result.Results.TryGetValue("msg", out var msg) ? msg.GetConst() : "unknown MI error";
            throw new InvalidOperationException(message);
        }

        return result;
    }

    private MiCommandResult SendExecCommand(string command)
    {
        var token = Interlocked.Increment(ref _nextToken);
        WriteLine($"{token}-{command}");
        var records = new List<MiRecord>();
        MiRecord? resultRecord = null;
        MiRecord? stopRecord = null;

        while (true)
        {
            var record = TakeRecord(TimeSpan.FromSeconds(60));
            if (record.Kind == MiRecordKind.Prompt)
            {
                continue;
            }

            records.Add(record);
            if (record.Kind == MiRecordKind.Result && record.Token == token)
            {
                resultRecord = record;
                if (!string.Equals(record.ClassName, "running", StringComparison.Ordinal))
                {
                    break;
                }
            }

            if (record.Kind == MiRecordKind.ExecAsync &&
                string.Equals(record.ClassName, "stopped", StringComparison.Ordinal))
            {
                stopRecord = record;
                if (resultRecord is not null)
                {
                    break;
                }
            }
        }

        if (resultRecord is null)
        {
            throw new InvalidOperationException($"No MI exec result was received for command '{command}'.");
        }

        return new MiCommandResult(resultRecord, records, stopRecord);
    }

    private void WriteLine(string line)
    {
        if (_process is null)
        {
            throw new InvalidOperationException("Debugger process was not started.");
        }

        WriteRawLog("IN", line);
        _process.StandardInput.WriteLine(line);
        _process.StandardInput.Flush();
    }

    private MiRecord TakeRecord(TimeSpan timeout)
    {
        if (_records.TryTake(out var record, timeout))
        {
            return record;
        }

        if (_process is not null && _process.HasExited)
        {
            throw new InvalidOperationException("Debugger process exited unexpectedly.");
        }

        throw new TimeoutException("Timed out waiting for MI response.");
    }

    private void WaitForPrompt(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var remaining = deadline - DateTime.UtcNow;
            var record = TakeRecord(remaining);
            if (record.Kind == MiRecordKind.Prompt)
            {
                return;
            }
        }

        throw new TimeoutException("Timed out waiting for the initial MI prompt.");
    }

    private async Task ReadStdoutAsync()
    {
        try
        {
            while (_process is not null && !_process.HasExited)
            {
                var line = await _process.StandardOutput.ReadLineAsync().ConfigureAwait(false);
                if (line is null)
                {
                    break;
                }

                WriteRawLog("OUT", line);
                _records.Add(MiRecord.Parse(line));
            }
        }
        catch
        {
        }
    }

    private async Task ReadStderrAsync()
    {
        try
        {
            while (_process is not null && !_process.HasExited)
            {
                var line = await _process.StandardError.ReadLineAsync().ConfigureAwait(false);
                if (line is null)
                {
                    break;
                }

                WriteRawLog("ERR", line);
                _records.Add(new MiRecord(MiRecordKind.LogStream, null, "stderr", new Dictionary<string, MiValue>(), line, line));
            }
        }
        catch
        {
        }
    }

    private void WriteRawLog(string channel, string line)
    {
        if (string.IsNullOrWhiteSpace(_rawLogPath))
        {
            return;
        }

        try
        {
            lock (_rawLogLock)
            {
                File.AppendAllText(_rawLogPath, $"{channel}: {line}{Environment.NewLine}");
            }
        }
        catch
        {
        }
    }

    private static long ParseMiNumber(string value)
    {
        if (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            return long.Parse(value[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        }

        return long.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture);
    }

    private static byte[] ParseHexBytes(string hex)
    {
        var clean = hex.Replace(" ", string.Empty, StringComparison.Ordinal);
        if (clean.Length % 2 != 0)
        {
            throw new InvalidOperationException($"Invalid hex byte string '{hex}'.");
        }

        var bytes = new byte[clean.Length / 2];
        for (var i = 0; i < bytes.Length; i++)
        {
            bytes[i] = byte.Parse(clean.AsSpan(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        }

        return bytes;
    }

    private static IEnumerable<string> EnumerateBreakpointInsertCommands(long address)
    {
        var dec = address.ToString(CultureInfo.InvariantCulture);
        var hex = "0x" + address.ToString("X", CultureInfo.InvariantCulture);
        yield return $"break-insert {hex}";
        yield return $"break-insert {dec}";
        yield return $"break-insert *{hex}";
        yield return $"break-insert *{dec}";
    }

    private static string? ExtractBreakpointId(Dictionary<string, MiValue> results)
    {
        if (results.TryGetValue("bkpt", out var breakpoint))
        {
            if (breakpoint.TryGet("number", out var number))
            {
                return number.GetConst();
            }
        }

        if (results.TryGetValue("bkpts", out var breakpoints))
        {
            foreach (var item in breakpoints.EnumerateList())
            {
                if (item.TryGet("number", out var number))
                {
                    return number.GetConst();
                }
            }
        }

        return null;
    }
}

internal sealed class DisassembledInstruction
{
    public long Address { get; set; }
    public string Instruction { get; set; } = string.Empty;
}

internal sealed class MiCommandResult
{
    public MiCommandResult(MiRecord resultRecord, List<MiRecord> records, MiRecord? stopRecord = null)
    {
        ResultClass = resultRecord.ClassName;
        Results = resultRecord.Results;
        Records = records;
        StopRecord = stopRecord;
        Streams = records
            .Where(record => record.Kind is MiRecordKind.ConsoleStream or MiRecordKind.TargetStream or MiRecordKind.LogStream)
            .Select(record => record.Text)
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToList();
        StopReason = stopRecord is not null && stopRecord.Results.TryGetValue("reason", out var reason)
            ? reason.GetConst()
            : string.Empty;
    }

    public string ResultClass { get; }
    public Dictionary<string, MiValue> Results { get; }
    public List<MiRecord> Records { get; }
    public MiRecord? StopRecord { get; }
    public List<string> Streams { get; }
    public string StopReason { get; }
}

internal enum MiRecordKind
{
    Prompt,
    Result,
    ExecAsync,
    StatusAsync,
    NotifyAsync,
    ConsoleStream,
    TargetStream,
    LogStream,
    Other
}

internal sealed class MiRecord
{
    public MiRecord(MiRecordKind kind, int? token, string className, Dictionary<string, MiValue> results, string raw, string text)
    {
        Kind = kind;
        Token = token;
        ClassName = className;
        Results = results;
        Raw = raw;
        Text = text;
    }

    public MiRecordKind Kind { get; }
    public int? Token { get; }
    public string ClassName { get; }
    public Dictionary<string, MiValue> Results { get; }
    public string Raw { get; }
    public string Text { get; }

    public static MiRecord Parse(string line)
    {
        if (string.Equals(line, "(gdb)", StringComparison.Ordinal))
        {
            return new MiRecord(MiRecordKind.Prompt, null, string.Empty, new Dictionary<string, MiValue>(), line, line);
        }

        var index = 0;
        int? token = null;
        while (index < line.Length && char.IsDigit(line[index]))
        {
            index++;
        }

        if (index > 0)
        {
            token = int.Parse(line[..index], CultureInfo.InvariantCulture);
        }

        if (index >= line.Length)
        {
            return new MiRecord(MiRecordKind.Other, token, string.Empty, new Dictionary<string, MiValue>(), line, line);
        }

        var prefix = line[index];
        var rest = line[(index + 1)..];
        if (prefix is '~' or '@' or '&')
        {
            var text = rest.Length > 0 ? MiParser.UnescapeCString(rest) : string.Empty;
            var kind = prefix switch
            {
                '~' => MiRecordKind.ConsoleStream,
                '@' => MiRecordKind.TargetStream,
                '&' => MiRecordKind.LogStream,
                _ => MiRecordKind.Other
            };
            return new MiRecord(kind, token, string.Empty, new Dictionary<string, MiValue>(), line, text);
        }

        var className = rest;
        var results = new Dictionary<string, MiValue>();
        var commaIndex = rest.IndexOf(',');
        if (commaIndex >= 0)
        {
            className = rest[..commaIndex];
            var parser = new MiParser(rest[(commaIndex + 1)..]);
            results = parser.ParseResultDictionary();
        }

        var kind2 = prefix switch
        {
            '^' => MiRecordKind.Result,
            '*' => MiRecordKind.ExecAsync,
            '+' => MiRecordKind.StatusAsync,
            '=' => MiRecordKind.NotifyAsync,
            _ => MiRecordKind.Other
        };

        return new MiRecord(kind2, token, className, results, line, line);
    }
}

internal sealed class MiParser
{
    private readonly string _text;
    private int _position;

    public MiParser(string text)
    {
        _text = text;
    }

    public Dictionary<string, MiValue> ParseResultDictionary()
    {
        var results = new Dictionary<string, MiValue>(StringComparer.Ordinal);
        while (!IsEnd())
        {
            var result = ParseResult();
            results[result.Name] = result.Value;
            if (Peek() == ',')
            {
                _position++;
            }
        }

        return results;
    }

    public static string UnescapeCString(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length >= 2 && trimmed[0] == '"' && trimmed[^1] == '"')
        {
            trimmed = trimmed[1..^1];
        }

        var builder = new StringBuilder(trimmed.Length);
        for (var i = 0; i < trimmed.Length; i++)
        {
            var ch = trimmed[i];
            if (ch != '\\')
            {
                builder.Append(ch);
                continue;
            }

            if (i + 1 >= trimmed.Length)
            {
                break;
            }

            i++;
            builder.Append(trimmed[i] switch
            {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                _ => trimmed[i]
            });
        }

        return builder.ToString();
    }

    private MiResultEntry ParseResult()
    {
        var name = ParseName();
        Expect('=');
        var value = ParseValue();
        return new MiResultEntry(name, value);
    }

    private MiValue ParseValue()
    {
        return Peek() switch
        {
            '"' => MiValue.FromConst(ParseCString()),
            '{' => ParseTuple(),
            '[' => ParseList(),
            _ => MiValue.FromConst(ParseBareWord())
        };
    }

    private MiValue ParseTuple()
    {
        Expect('{');
        var entries = new List<MiResultEntry>();
        while (Peek() != '}')
        {
            entries.Add(ParseResult());
            if (Peek() == ',')
            {
                _position++;
            }
        }

        Expect('}');
        return MiValue.FromTuple(entries);
    }

    private MiValue ParseList()
    {
        Expect('[');
        var values = new List<MiValue>();
        var entries = new List<MiResultEntry>();

        while (Peek() != ']')
        {
            if (LooksLikeResult())
            {
                entries.Add(ParseResult());
            }
            else
            {
                values.Add(ParseValue());
            }

            if (Peek() == ',')
            {
                _position++;
            }
        }

        Expect(']');
        return MiValue.FromList(values, entries);
    }

    private bool LooksLikeResult()
    {
        var first = Peek();
        if (first is '{' or '[' or '"' or '\0')
        {
            return false;
        }

        var start = _position;
        while (start < _text.Length && _text[start] is not '=' and not ',' and not ']' and not '}')
        {
            if (_text[start] == '"')
            {
                return false;
            }

            start++;
        }

        return start < _text.Length && _text[start] == '=';
    }

    private string ParseName()
    {
        var start = _position;
        while (!IsEnd() && Peek() is not '=' and not ',' and not ']' and not '}')
        {
            _position++;
        }

        return _text[start.._position];
    }

    private string ParseCString()
    {
        var start = _position;
        Expect('"');
        var escaped = false;
        while (!IsEnd())
        {
            var ch = _text[_position++];
            if (escaped)
            {
                escaped = false;
                continue;
            }

            if (ch == '\\')
            {
                escaped = true;
                continue;
            }

            if (ch == '"')
            {
                break;
            }
        }

        return UnescapeCString(_text[start.._position]);
    }

    private string ParseBareWord()
    {
        var start = _position;
        while (!IsEnd() && Peek() is not ',' and not ']' and not '}')
        {
            _position++;
        }

        return _text[start.._position];
    }

    private void Expect(char ch)
    {
        if (Peek() != ch)
        {
            throw new InvalidOperationException($"Expected '{ch}' in MI text '{_text}'.");
        }

        _position++;
    }

    private char Peek()
        => IsEnd() ? '\0' : _text[_position];

    private bool IsEnd()
        => _position >= _text.Length;
}

internal readonly struct MiResultEntry(string name, MiValue value)
{
    public string Name { get; } = name;
    public MiValue Value { get; } = value;
}

internal sealed class MiValue
{
    private MiValue()
    {
    }

    public string? Const { get; private init; }
    public List<MiResultEntry>? TupleEntries { get; private init; }
    public List<MiValue>? ListValues { get; private init; }
    public List<MiResultEntry>? ListEntries { get; private init; }

    public static MiValue FromConst(string value)
        => new() { Const = value };

    public static MiValue FromTuple(List<MiResultEntry> entries)
        => new() { TupleEntries = entries };

    public static MiValue FromList(List<MiValue> values, List<MiResultEntry> entries)
        => new() { ListValues = values, ListEntries = entries };

    public string GetConst()
        => Const ?? throw new InvalidOperationException("MI value is not a const string.");

    public MiValue Get(string name)
    {
        if (TupleEntries is not null)
        {
            foreach (var entry in TupleEntries)
            {
                if (string.Equals(entry.Name, name, StringComparison.Ordinal))
                {
                    return entry.Value;
                }
            }
        }

        if (ListEntries is not null)
        {
            foreach (var entry in ListEntries)
            {
                if (string.Equals(entry.Name, name, StringComparison.Ordinal))
                {
                    return entry.Value;
                }
            }
        }

        throw new KeyNotFoundException($"MI field '{name}' was not found.");
    }

    public bool TryGet(string name, out MiValue value)
    {
        if (TupleEntries is not null)
        {
            foreach (var entry in TupleEntries)
            {
                if (string.Equals(entry.Name, name, StringComparison.Ordinal))
                {
                    value = entry.Value;
                    return true;
                }
            }
        }

        if (ListEntries is not null)
        {
            foreach (var entry in ListEntries)
            {
                if (string.Equals(entry.Name, name, StringComparison.Ordinal))
                {
                    value = entry.Value;
                    return true;
                }
            }
        }

        value = null!;
        return false;
    }

    public IEnumerable<MiValue> EnumerateList()
    {
        if (ListValues is not null)
        {
            return ListValues;
        }

        if (ListEntries is not null)
        {
            return ListEntries.Select(entry => MiValue.FromTuple([entry]));
        }

        throw new InvalidOperationException("MI value is not a list.");
    }
}
