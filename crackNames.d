
import std.algorithm;
import std.array;
import std.ascii : digits, uppercase;
import std.ascii : isAlpha, isDigit, isUpper, isLower;
import std.conv : ConvException, to;
import std.file : read;
import std.getopt : defaultGetoptFormatter, getopt, GetOptException, GetoptResult;
import std.json : JSONOptions, JSONValue, toJSON;
import std.math : ceil, floor, pow;
import std.numeric : gcd;
import std.parallelism : defaultPoolThreads, taskPool, totalCPUs;
import std.range : assumeSorted, SortedRange, retro;
import std.stdio : stderr, stdout, writeln, writefln;
import std.string;


// FNV-1 32-bit
const uint InitialFNV32 = 2166136261U;
uint fnvHash32(uint hash, const char[] text) pure nothrow @nogc @safe
{
    foreach(octet; text)
    {
        hash *= 16777619U;
        hash = hash ^ octet;
    }
    return hash;
}

// FNV-1 64-bit
const ulong InitialFNV64 = 14695981039346656037U;
ulong fnvHash64(ulong hash, const char[] text) pure nothrow @nogc @safe
{
    foreach(octet; text)
    {
        hash *= 1099511628211U;
        hash = hash ^ octet;
    }
    return hash;
}

struct Hashes
{
    SortedRange!(uint[]) fnv32;
    SortedRange!(ulong[]) fnv64;
    bool enable32bit = false;
}

Hashes loadHashes(string filename)
{
    Hashes hashes;
    uint[] fnv32 = [];
    ulong[] fnv64 = [];
    string text = cast(string)read(filename);
    foreach (string line; splitter(text, '\n'))
    {
        if (line.length == 0 || line[0] == '#')
        {
            continue;
        }
        auto number = line.chomp;
        try
        {
            if (line.length == 16)
            {
                fnv64 ~= to!ulong(line, 16);
            } else
            {
                fnv32 ~= to!uint(number);
            }
        } catch (ConvException)
        {
            // Ignore
        }
    }
    return Hashes(fnv32.sort.uniq.array.assumeSorted, fnv64.sort.uniq.array.assumeSorted);
}

string[] loadNames(string[] filenames)
{
    string[] names;
    foreach (filename; filenames)
    {
        string text = cast(string)read(filename);
        foreach (string line; splitter(text, '\n'))
        {
            line = line.stripRight;
            if (line.length < 1 || line[0] == '#')
            {
                continue;
            }
            names ~= line;
        }
    }
    return names.sort.uniq!((a, b) => a.toLower() == b.toLower()).array;
}

bool isRoman(dchar c)
{
    return "IVXLCDM".canFind(c.toUpper());
}

bool isSmallRoman(dchar c)
{
    return "IVX".canFind(c.toUpper());
}

bool isWord(dchar c)
{
    return c.isAlpha || c == '(' || c == ')';
}

string modifyLetters(string letters, int value)
{
    assert(!letters.empty);
    if (value == 0)
    {
        return letters;
    }
    dchar base = letters.back.toUpper();
    bool isLower = letters.back.isLower();
    assert(base >= '0' && base <= 'Z');
    int c = base + value;
    int lowerWrap = '0';
    int upperWrap = 'Z';
    int rangeSize = 'Z' - '0' + 1;
    bool lowerWrapped = base > '9';
    if (c < lowerWrap && base <= '9')
    {
        c += rangeSize;
        lowerWrapped = true;
    }

    if (c < 'A' && lowerWrapped)
    {
        c -= 'A' - lowerWrap;
    } else if (c > upperWrap)
    {
        c -= rangeSize;
        lowerWrapped = false;
    }
    if (c > '9' && !lowerWrapped)
    {
        c += upperWrap - '9';
    }

    auto baseLetters = letters[0..$ - 1];
    int letterCount = uppercase.length + digits.length;
    if (c < lowerWrap)
    {
        if (letters.length > 1)
        {
            baseLetters = modifyLetters(baseLetters, ((c + 1 - lowerWrap) / letterCount) - 1);
            c = '9' + ((c + 1 - lowerWrap) % letterCount);
            if (baseLetters == "-")
            {
                return c == '9' ? "" : "-";
            }
            if (c < lowerWrap)
            {
                c += rangeSize;
            }
        } else if (c + 1 == lowerWrap)
        {
            return "";
        } else
        {
            return "-";
        }
    }

    if (c > upperWrap)
    {
        int increment = (c - 1 - upperWrap) / letterCount + 1;
        if (baseLetters.empty)
        {
            baseLetters ~= isLower ? "a" : "A";
            increment--;
        }
        baseLetters = modifyLetters(baseLetters, increment);
        c = 'A' + ((c - 1 - upperWrap) % letterCount);
        if (c > upperWrap)
        {
            c -= rangeSize;
        }
    }
    dchar ch = c;
    if (isLower)
    {
        ch = ch.toLower();
    }
    return baseLetters ~ ch.to!string;
}

int fromRoman(string roman)
{
    int result = 0;
    int[dchar] values = ['M': 1000, 'D': 500, 'C': 100, 'L': 50, 'X': 10, 'V': 5, 'I': 1];
    int largest = 0;
    int count = 0;

    foreach_reverse (numeral; roman)
    {
        int value = values.get(numeral.toUpper(), 0);
        if (value <= 0)
        {
            return 0;
        }

        if (value >= largest)
        {
            if (value < 1000)
            {
                if (value == largest)
                {
                    if ([5, 50, 500].canFind(value))
                    {
                        return 0;
                    }
                    count++;
                } else
                {
                    count = 1;
                }
                if (count > 3)
                {
                    return 0;
                }
            } else
            {
                count = 1;
            }
            result += value;
        } else
        {
            if ((largest / value != 5 && largest / value != 10) ||
                (result / value != 5 && result / value != 10) ||
                [5, 50, 500].canFind(value))
            {
                return 0;
            }
            result -= value;
            count = 0;
        }
        if (value > largest)
        {
            largest = value;
        }
    }
    return result;
}

string toRoman(int number)
{
    string[int] values = [1000: "M", 900: "CM", 500: "D", 400: "CD",
                          100:  "C", 90:  "XC", 50:  "L", 40:  "XL",
                          10:   "X", 9:   "IX", 5:   "V", 4:   "IV", 1: "I"];

    string result = "";

    foreach (group; values.keys.sort.retro)
    {
        while (number >= group)
        {
            result ~= values[group];
            number -= group;
        }
    }

    return result;
}

enum NameType
{
    Unknown,
    Word,
    Number,
    RomanNumber,
    WordNumber,
    WordRomanNumber,
    WordLetter,
    WordNumberLetter,
    Separator
}

struct NameHash;
class NameCombinations(T);

class NamePart
{
    string name;
    NameType type;
    string[] separators;
    string[] siblings;
    NamePart[string] childs;
    string[] expandedValues;
    string[] expandedNumbers;
    ulong combinations;

    this()
    {
        this(NameType.Unknown);
    }

    this(NameType type)
    {
        this.type = type;
        this.childs = new NamePart[string];
    }

    this(NamePart other)
    {
        this.name = other.name;
        this.type = other.type;
        this.separators = other.separators.dup;
        this.siblings = other.siblings.dup;
        this.childs = other.childs.dup;
    }

    NamePart dup()
    {
        return new NamePart(this);
    }

    string id()
    {
        auto id = this.name;
        if (this.separators.length > 0)
        {
            assert(this.separators.length == 1);
            id ~= this.separators.front;
        }
        return id.toLower();
    }

    void capitaliseName(string name)
    {
        if (!this.name.any!(a => a.isUpper) && name.any!(a => a.isUpper))
        {
            this.name = name;
        }
    }

    string baseName()
    {
        if ((this.type == NameType.WordNumber && this.name[$-2..$] == "%d") ||
            (this.type == NameType.WordLetter && this.name[$-2..$] == "%c") ||
            (this.type == NameType.WordRomanNumber && this.name[$-2..$] == "%r"))
        {
            return this.name[0..$-2];
        } else if (this.type != NameType.Number)
        {
            return this.name.stripRight!(a => a.isDigit);
        }
        return this.name;
    }

    void addSeparator(string separator)
    {
        assert(!separator.empty);
        if (!this.separators.canFind(separator))
        {
            this.separators ~= separator;
        }
    }

    void addSeparators(string[] separators)
    {
        foreach (separator; separators)
        {
            this.addSeparator(separator);
        }
    }

    void addSibling(string newSibling)
    {
        assert(!newSibling.empty);
        bool found = false;
        foreach (index, sibling; this.siblings)
        {
            if (sibling.toLower() == newSibling.toLower())
            {
                found = true;
                if (!sibling.any!(a => a.isUpper) && newSibling.any!(a => a.isUpper))
                {
                    this.siblings[index] = newSibling;
                }
                break;
            }
        }
        if (!found)
        {
            this.siblings ~= newSibling;
        }
    }

    void addSiblings(string[] siblings)
    {
        foreach (sibling; siblings)
        {
            this.addSibling(sibling);
        }
    }

    void merge(NamePart other)
    {
        assert(this.type == other.type);
        this.capitaliseName(other.name);
        this.addSeparators(other.separators);
        this.addSiblings(other.siblings);
        foreach (id, child; other.childs)
        {
            if (id in this.childs)
            {
                this.childs[id].merge(child);
            } else
            {
                this.childs[id] = child;
            }
        }
    }

    void expandNumbers(int expand)
    {
        long minValue = long.max;
        long maxValue = -1;
        ulong minWidth = ulong.max;
        ulong[] zeroPad;
        long[] numbers;
        bool tooBig = false;

        foreach (sibling; this.siblings)
        {
            if (!sibling.all!(a => a.isDigit))
            {
                continue;
            }

            long number = sibling.to!long;
            if (number < minValue)
            {
                minValue = number;
            }
            if (number > maxValue)
            {
                maxValue = number;
            }
            if (maxValue - minValue >= 3000)
            {
                tooBig = true;
                break;
            }
            if (sibling.length < minWidth)
            {
                minWidth = sibling.length;
            }
            if (sibling.front == '0' && sibling.length > 1)
            {
                if (!zeroPad.canFind(sibling.length))
                {
                    zeroPad ~= sibling.length;
                }
            }
            numbers ~= number;
        }
        if (tooBig)
        {
            zeroPad = [];
            numbers = [];
            auto sortedSiblings = this.siblings.filter!(a => a.all!(a => a.isDigit))
                                               .array.sort!((a, b) => a.length < b.length ||
                                                                      a.length == b.length && a < b);
            foreach (sibling; sortedSiblings)
            {
                long number = sibling.to!long;
                long numberStart = max(number - cast(long)ceil(expand / 2.0), 0);
                long numberEnd = number + expand;
                for (long i = numberStart; i <= numberEnd; i++)
                {
                    auto str = i.to!string;
                    if (sibling.front == '0' && sibling.length > 1)
                    {
                        str = str.rightJustify(sibling.length, '0');
                    } else if (str.length < sibling.length)
                    {
                        auto str2 = str.rightJustify(sibling.length, '0');
                        this.expandedNumbers ~= str2;
                    }
                    this.expandedNumbers ~= str;
                }
            }
            this.expandedNumbers.length -= this.expandedNumbers.sort.uniq.copy(this.expandedNumbers).length;
        } else
        {
            assert(!numbers.empty);
            zeroPad.sort.copy(zeroPad);

            long minStep = 1;
            if (numbers.length > 1)
            {
                minStep = numbers.front;
                foreach (number; numbers)
                {
                    minStep = gcd(number, minStep);
                    if (minStep < 5)
                    {
                        minStep = 1;
                        break;
                    }
                }
            }
            long numberStart = max(minValue - cast(long)ceil(expand / 2.0) * minStep, 0);
            long numberEnd = maxValue + expand * minStep;
            ulong maxPad = ulong.max;
            if (!zeroPad.empty)
            {
                maxPad = zeroPad.maxElement;
            }
            for (long i = numberStart; i <= numberEnd; i += minStep)
            {
                auto str = i.to!string;
                if (str.length < maxPad && maxPad < ulong.max)
                {
                    foreach (width; zeroPad)
                    {
                        this.expandedNumbers ~= str.rightJustify(width, '0');
                    }
                    continue;
                } else if (str.length < minWidth)
                {
                    if (str.length < minValue.to!string.length)
                    {
                        this.expandedNumbers ~= str;
                    }
                    str = str.rightJustify(minWidth, '0');
                }
                this.expandedNumbers ~= str;
            }
        }
    }

    ulong expand(int expand)
    {
        if (this.type == NameType.Number || this.type == NameType.WordNumber)
        {
            if (expand > 0)
            {
                this.expandNumbers(expand);
            } else
            {
                this.expandedNumbers = this.siblings.sort.array;
            }
        } else if (this.type == NameType.WordLetter || this.type == NameType.WordNumberLetter)
        {
            assert(!this.siblings.empty);
            if (expand > 0)
            {
                if (this.type == NameType.WordNumberLetter)
                {
                    this.expandNumbers(expand);
                }
                auto sortedSiblings = this.siblings.sort;
                string[] possibleValues;
                string[] uppercaseValues;
                bool anyOverlap = false;

                foreach (sibling; sortedSiblings)
                {
                    string letterStart = modifyLetters(sibling, cast(int)floor(expand / -2.0));
                    if (letterStart < "0")
                    {
                        letterStart = sibling.back.isLower ? "a" : "A";
                    }

                    string letterEnd = modifyLetters(sibling, expand).toUpper();
                    auto letters = letterStart;
                    bool isDone = false;
                    do
                    {
                        string uppercaseLetters = letters.toUpper();
                        if (uppercaseLetters == letterEnd)
                        {
                            isDone = true;
                        }
                        if (uppercaseValues.canFind(uppercaseLetters))
                        {
                            anyOverlap = true;
                        } else
                        {
                            uppercaseValues ~= uppercaseLetters;
                            possibleValues ~= letters;
                        }
                        letters = modifyLetters(letters, 1);
                    } while (!isDone);
                }
                if (anyOverlap)
                {
                    this.expandedValues = possibleValues;
                } else
                {
                    this.expandedValues = sortedSiblings.array;
                }
            } else
            {
                this.expandedValues = this.siblings.sort.array;
            }
        } else if (this.type == NameType.RomanNumber || this.type == NameType.WordRomanNumber)
        {
            assert(!this.siblings.empty);
            if (expand > 0)
            {
                int minValue = int.max;
                int maxValue = 0;
                string[] invalid;
                int[] numbers;
                foreach (sibling; this.siblings)
                {
                    auto value = fromRoman(sibling);
                    if (value > 0)
                    {
                        int numberStart = max(value - cast(int)ceil(expand / 2.0), 1);
                        int numberEnd = value + expand;
                        for (int n = numberStart; n <= numberEnd; n++)
                        {
                            if (!numbers.canFind(n))
                            {
                                numbers ~= n;
                            }
                        }
                    } else
                    {
                        invalid ~= sibling;
                    }
                }
                foreach (number; numbers.sort)
                {
                    this.expandedValues ~= toRoman(number);
                }
                this.expandedValues ~= invalid.sort.array;
            } else
            {
                this.expandedValues = this.siblings.sort.array;
            }
        } else
        {
            this.expandedValues = this.siblings.sort.array;
        }
        this.combinations = 0;
        auto count = this.countItems();
        if (this.childs.empty)
        {
            this.combinations = count;
        } else
        {
            foreach (child; this.childs)
            {
                this.combinations += count * child.expand(expand);
            }
        }
        return this.combinations;
    }

    T reduce(T)(uint threads, T input, ref T result, string parentId, scope T delegate(T, ref T, string, NamePart, bool) reducer)
    {
        auto childInput = reducer(input, result, parentId, this, this.childs.empty);
        if (this.childs.length > 1)
        {
            if (this.combinations > 2000 / threads)
            {
                foreach (id; taskPool.parallel(this.childs.keys, 1))
                {
                    this.childs[id].reduce(threads, childInput, result, id, reducer);
                }
            } else
            {
                foreach (id; this.childs.keys)
                {
                    this.childs[id].reduce(threads, childInput, result, id, reducer);
                }
            }
        } else if (this.childs.length == 1)
        {
            auto id = this.childs.keys.front;
            this.childs[id].reduce(threads, childInput, result, id, reducer);
        }
        return result;
    }

    static string[] expandNumberPattern(string pattern, string suffix, string[] values)
    {
        string[] names;
        auto placeholders = pattern.count("%d");
        if (placeholders == 0)
        {
            names ~= pattern ~ suffix;
        } else if (placeholders == 1)
        {
            foreach (value; values)
            {
                names ~= pattern.replace("%d", value) ~ suffix;
            }
        } else
        {
            foreach (value; values)
            {
                names ~= expandNumberPattern(pattern.replace("%d", value), suffix, values);
            }
        }
        return names;
    }

    static ulong countNumberPattern(string pattern, ulong valueCount)
    {
        return pow(valueCount, pattern.count("%d"));
    }

    ulong countItems()
    {
        auto count = this.separators.empty ? 1 : this.separators.length;

        if (this.type == NameType.Number || this.type == NameType.WordNumber)
        {
            count *= NamePart.countNumberPattern(this.name, this.expandedNumbers.length);
        } else
        {
            count *= this.expandedValues.length == 0 ? 1 : this.expandedValues.length;
            count *= NamePart.countNumberPattern(this.name, this.expandedNumbers.length);
        }
        return count;
    }
}

class NameForestBuilder
{
public:
    NamePart[string] forest;
    ulong combinations;

    this(uint threads, bool recognizeRoman)
    {
        this.forest = new NamePart[string];
        this.threads = threads;
        this.recognizeRoman = recognizeRoman;
    }

    void processAll(string[] names)
    {
        foreach (name; names)
        {
            if (name.length > 500)
            {
                stderr.writefln("Ignoring name %s...%s because it's too long", name[0..50], name[$ - 50..$]);
                continue;
            }
            this.processName(name);
        }
    }

    void merge()
    {
        this.deepMerge(this.forest);
    }

    void expand(int expand)
    {
        this.combinations = 0;
        foreach (id, tree; this.forest)
        {
            this.combinations += tree.expand(expand);
        }
    }

    T reduce(T)(ref T result, scope T delegate(T, ref T, string, NamePart, bool) reducer)
    {
        auto input = result;
        if (this.forest.length > 1 && this.combinations > 1000 / this.threads)
        {
            foreach (id; taskPool.parallel(this.forest.keys, 1))
            {
                this.forest[id].reduce(this.threads, input, result, id, reducer);
            }
        } else
        {
            foreach (id, tree; this.forest)
            {
                tree.reduce(this.threads, input, result, id, reducer);
            }
        }
        return result;
    }

    string toJSON(in bool pretty = false, in JSONOptions options = JSONOptions.none)
    {
        auto result = JSONValue.emptyObject;
        result["childs"] = JSONValue.emptyObject;
        this.reduce(result,
                   (JSONValue parent, ref JSONValue v, string id, NamePart part, bool)
        {
            JSONValue json = JSONValue.emptyObject;
            json.object["name"] = JSONValue(part.name);
            json.object["type"] = JSONValue(part.type.to!NameType.to!string);
            json.object["separators"] = JSONValue(part.separators);
            json.object["siblings"] = JSONValue(part.siblings);
            json.object["expandedNumbers"] = JSONValue(part.expandedNumbers);
            json.object["expandedValues"] = JSONValue(part.expandedValues);
            json.object["combinations"] = JSONValue(part.combinations);
            json.object["childs"] = JSONValue.emptyObject;

            synchronized
            {
                parent["childs"][id] = json;
            }
            return json;
        });
        return result["childs"].toJSON(pretty, options);
    }

    struct PatternValues
    {
        bool useNames;
        bool useNumbers;
        string[] names;
        ulong min;
        ulong max;

        this(string[] names)
        {
            this.names ~= names;
            this.useNames = true;
            this.useNumbers = false;
        }

        this(ulong min, ulong max)
        {
            this.min = min;
            this.max = max;
            this.useNames = false;
            this.useNumbers = true;
        }

        this(ulong min, ulong max, string[] names)
        {
            this.min = min;
            this.max = max;
            this.names ~= names;
            this.useNames = true;
            this.useNumbers = true;
        }

        void merge(string[] names)
        {
            this.names ~= names;
        }

        @property string toString()
        {
            string result = "";
            if (this.useNumbers)
            {
                if (this.min == this.max)
                {
                    result = "[" ~ this.min.to!string ~ "]";
                } else
                {
                    result = "[" ~ this.min.to!string ~ "-" ~ this.max.to!string ~ "]";
                }
            }
            if (this.useNames)
            {
                if (!this.names.empty)
                {
                    result ~= "{" ~ this.names.join(';') ~ "}";
                }
            }
            return result;
        }
    }

    struct Pattern
    {
        string pattern;
        PatternValues[] values;
    }

    Pattern[] toPatterns()
    {
        Pattern[] patterns;
        return this.reduce(patterns,
                   (Pattern[] input, ref Pattern[] result, string id, NamePart part, bool isLeaf)
        {
            string prefix = part.name;
            auto siblings = part.siblings;
            if ((part.type == NameType.RomanNumber || part.type == NameType.WordRomanNumber) && siblings.length == 1)
            {
                prefix = prefix.replace("%r", siblings.front);
                siblings = [];
            }
            if (!part.separators.empty)
            {
                prefix ~= part.separators.front;
            }
            Pattern[] subresult;
            PatternValues values;
            if (part.type == NameType.Number || part.type == NameType.WordNumber)
            {
                auto numbers = siblings.map!(a => a.to!ulong);
                values = PatternValues(numbers.minElement, numbers.maxElement);
            } else if (part.type == NameType.WordNumberLetter)
            {
                auto numbers = siblings.filter!(a => a.isNumeric).map!(a => a.to!ulong);
                values = PatternValues(numbers.minElement, numbers.maxElement, siblings.filter!(a => !a.isNumeric).array);
            } else
            {
                values = PatternValues(siblings.filter!(a => !a.isNumeric).array);
            }

            if (input.empty)
            {
                subresult ~= Pattern(prefix, [values]);
            } else
            {
                foreach (subPattern; input)
                {
                    subresult ~= Pattern(subPattern.pattern ~ prefix, subPattern.values ~ values);
                }
            }
            if (isLeaf)
            {
                synchronized
                {
                    result ~= subresult;
                }
            }
            return subresult;
        });
    }

    class NameCombinations(T)
    {
        public:
            this(T root, scope T delegate(T, string, string) merge)
            {
                this.mergeFunction = merge;
                this.root = root;
            }

            this(NameCombinations!T names)
            {
                this.mergeFunction = names.mergeFunction;
                this.parentNames = names;
                this.root = names.root;
            }

            void opOpAssign(string op: "~")(string name)
            {
                this.names ~= NameDetails(name, name.toLower());
            }

            void opOpAssign(string op: "~")(string[] names)
            {
                foreach (name; names)
                {
                    this ~= name;
                }
            }

            int opApply(scope int delegate(T) callback)
            {
                if (this.parentNames)
                {
                    assert(!this.names.empty);
                    foreach (parentName; this.parentNames)
                    {
                        foreach (name; this.names)
                        {
                            auto result = callback(this.mergeFunction(parentName, name.name, name.lower));
                            if (result)
                            {
                                return result;
                            }
                        }
                    }
                    return 0;
                } else
                {
                    return callback(this.mergeFunction(this.root, "", ""));
                }
            }

        private:
            NameCombinations parentNames;
            T root;
            struct NameDetails
            {
                string name;
                string lower;
            };
            NameDetails[] names;
            T delegate(T, string, string) mergeFunction;
    }

    void traverse(T)(T root, scope T delegate(T, string, string) mergeFunction, void delegate(T) callback)
    {
        auto names = new NameCombinations!T(root, mergeFunction);
        this.reduce(names,
                   (NameCombinations!T parentCombinations, ref NameCombinations!T, string, NamePart part, bool isLeaf)
        {
            auto resultCombinations = new NameCombinations!T(parentCombinations);
            auto separators = part.separators;
            if (separators.empty)
            {
                separators = [""];
            }
            if (part.siblings.empty)
            {
                foreach (separator; separators)
                {
                    resultCombinations ~= part.name ~ separator;
                }
            } else
            {
                foreach (separator; separators)
                {
                    if (part.type == NameType.Number || part.type == NameType.WordNumber)
                    {
                        resultCombinations ~= NamePart.expandNumberPattern(part.name, separator, part.expandedNumbers);
                    } else
                    {
                        assert(!part.expandedValues.empty);
                        if (part.type == NameType.WordLetter || part.type == NameType.WordNumberLetter)
                        {
                            foreach (value; part.expandedValues)
                            {
                                resultCombinations ~= NamePart.expandNumberPattern(part.name.replace("%c", value), separator, part.expandedNumbers);
                            }
                        } else if (part.type == NameType.RomanNumber || part.type == NameType.WordRomanNumber)
                        {
                            foreach (value; part.expandedValues)
                            {
                                resultCombinations ~= NamePart.expandNumberPattern(part.name.replace("%r", value), separator, part.expandedNumbers);
                            }
                        } else
                        {
                            foreach (value; part.expandedValues)
                            {
                                resultCombinations ~= value ~ separator;
                            }
                        }
                    }
                }
            }

            if (isLeaf)
            {
                foreach (r; resultCombinations)
                {
                    callback(r);
                }
            }

            return resultCombinations;
        });
    }

    void listNames(void delegate(string) listName)
    {
        this.traverse!string("", (string parent, string current, string) => parent ~ current, listName);
    }

    struct NameHash
    {
        char[1000] name;
        uint nameLength;
        uint fnv32;
        ulong fnv64;
    }

    void findNames(Hashes hashes, void delegate(NameHash, bool) nameFound)
    {
        NameHash initial;
        initial.nameLength = 0;
        initial.fnv32 = InitialFNV32;
        initial.fnv64 = InitialFNV64;
        this.traverse!NameHash(initial, (NameHash parent, string current, string currentLower)
        {
            if (!current.empty)
            {
                parent.name[parent.nameLength..(parent.nameLength + current.length)] = current[];
                parent.nameLength += current.length;
            }
            if (hashes.enable32bit)
            {
                parent.fnv32 = fnvHash32(parent.fnv32, currentLower);
            } else
            {
                parent.fnv64 = fnvHash64(parent.fnv64, currentLower);
            }
            return parent;
        }, (NameHash nameHash)
        {
            if (hashes.enable32bit)
            {
                if (hashes.fnv32.canFind(nameHash.fnv32))
                {
                    nameFound(nameHash, true);
                }
            } else
            {
                if (hashes.fnv64.canFind(nameHash.fnv64))
                {
                    nameFound(nameHash, false);
                }
            }
        });
    }

protected:

    void processName(string name)
    {
        this.activeParent = this.forest;
        this.activeType = NameType.Unknown;
        this.activePart = new NamePart();
        this.activePart.type = this.activeType;
        this.fragmentStart = 0;

        foreach (position, c; name)
        {
            this.processChar(name, c, position);
        }
        this.processChar(name, 0, name.length);
    }

    static void deepMerge(NamePart[string] nameForest)
    {
        NameForestBuilder.merge(nameForest);
        foreach (tree; nameForest)
        {
            NameForestBuilder.deepMerge(tree.childs);
        }
    }

    static void merge(NamePart[string] nameForest)
    {
        NamePart[string] newNameForest;
        string[] seen;
        foreach (idA, treeA; nameForest)
        {
            seen ~= idA;
            NamePart activePart = null;
            bool removeEmpty = !treeA.childs.empty;
            if (![NameType.Word, NameType.WordLetter].canFind(treeA.type))
            {
                // Can't merge other types
                continue;
            }
            foreach (idB, treeB; nameForest)
            {
                if (seen.canFind(idB))
                {
                    continue;
                }
                if (treeA.type == NameType.WordLetter || treeB.type == NameType.WordLetter)
                {
                    auto baseName = treeA.baseName;
                    auto diff = treeB.name.length - baseName.length;
                    auto letterTree = treeA;
                    auto otherTree = treeB;
                    if (treeB.type == NameType.WordLetter)
                    {
                        baseName = treeB.baseName;
                        diff = treeA.name.length - baseName.length;
                        letterTree = treeB;
                        otherTree = treeA;
                    }
                    if (diff >= 1 && diff <= 2 && treeA.separators.empty == treeB.separators.empty && otherTree.name.startsWith(baseName))
                    {
                        auto sibling = otherTree.name[baseName.length..$];
                        letterTree.addSibling(sibling);
                        letterTree.addSeparators(otherTree.separators);
                        foreach (subtreeId, subtree; otherTree.childs)
                        {
                            letterTree.childs.update(subtreeId, () => subtree, (ref NamePart child) => child.merge(subtree));
                        }
                        otherTree.childs.clear();
                        if (treeA == otherTree)
                        {
                            removeEmpty = true;
                            break;
                        } else
                        {
                            nameForest.remove(idB);
                            continue;
                        }
                    }
                    // Can't merge
                    continue;
                }
                if (treeB.type != treeA.type)
                {
                    // Can't merge different types
                    continue;
                }
                foreach (subtreeBId, subtreeB; treeB.childs)
                {
                    if (activePart)
                    {
                        bool found = false;
                        foreach (subtreeZId, subtreeZ; activePart.childs)
                        {
                            if (subtreeBId == subtreeZId)
                            {
                                assert(treeB.separators == activePart.separators);
                                assert(treeB.separators.length == 1);
                                assert(treeB.siblings.length == 0);
                                assert(treeB.type == activePart.type);
                                assert(subtreeB.type == subtreeZ.type);

                                activePart.addSibling(treeB.name);
                                activePart.addSeparators(treeB.separators);
                                activePart.childs.update(subtreeBId, () => subtreeB, (ref NamePart child) => child.merge(subtreeB));

                                treeB.childs.remove(subtreeBId);
                                found = true;
                                break;
                            }
                        }
                        if (found)
                        {
                            continue;
                        }
                    }
                    foreach (subtreeAId, subtreeA; treeA.childs)
                    {
                        if (subtreeBId == subtreeAId)
                        {
                            assert(treeB.separators == treeA.separators);
                            assert(treeB.separators.length == 1);
                            assert(treeB.type == treeA.type);
                            assert(subtreeB.type == subtreeA.type);

                            if (activePart)
                            {
                                activePart.addSibling(treeB.name);
                            } else
                            {
                                activePart = new NamePart(treeA.type);
                                activePart.name = "%s";
                                activePart.addSibling(treeA.name);
                                activePart.addSibling(treeB.name);
                            }

                            activePart.addSeparators(treeA.separators);
                            activePart.addSeparators(treeB.separators);

                            activePart.childs.update(subtreeBId, () => subtreeA, (ref NamePart child) => child.merge(subtreeA));
                            activePart.childs[subtreeBId].merge(subtreeB);

                            treeA.childs.remove(subtreeAId);
                            treeB.childs.remove(subtreeBId);
                            break;
                        }
                    }
                }
                if (treeB.childs.empty)
                {
                    nameForest.remove(idB);
                }
            }
            if (activePart)
            {
                auto newId = activePart.id;
                if (newId in newNameForest)
                {
                    newNameForest[newId].merge(activePart);
                } else
                {
                    newNameForest[newId] = activePart;
                }
            }
            if (removeEmpty && treeA.childs.empty)
            {
                nameForest.remove(idA);
            }
        }
        foreach (id, nameTree; newNameForest)
        {
            assert(id !in nameForest);
            nameForest[id] = nameTree;
        }
    }

    void processChar(const string name, char c, ulong position)
    {
        switch (this.activeType)
        {
            case NameType.Word:
                if (c.isWord && (!c.isRoman || !this.recognizeRoman))
                {
                    return;
                }
                this.processWord(this.fetchFragment(name, position), c);
              break;
            case NameType.Number:
                if (c.isDigit)
                {
                    return;
                }
                this.processNumber(this.fetchFragment(name, position), c);
              break;
            case NameType.RomanNumber:
                if (c.isRoman)
                {
                    return;
                }
                this.processRoman(this.fetchFragment(name, position), c);
              break;
            case NameType.Separator:
                if (!c.isDigit && !c.isWord)
                {
                    return;
                }
                this.processSeparator(this.fetchFragment(name, position));
              break;
            case NameType.Unknown:
              // Just update type
              break;
            default:
              assert(false);
        }
        this.updateActiveType(c);
    }

    string peekFragment(const string name, const ulong position)
    {
        return name[this.fragmentStart..position];
    }

    string fetchFragment(const string name, const ulong position)
    {
        string fragment = this.peekFragment(name, position);
        this.fragmentStart = position;
        return fragment;
    }

    void updateActiveType(const char c)
    {
        if (this.recognizeRoman && c.isRoman)
        {
            this.activeType = NameType.RomanNumber;
        } else if (c.isWord)
        {
            this.activeType = NameType.Word;
        } else if (c.isDigit)
        {
            this.activeType = NameType.Number;
        } else
        {
            this.activeType = NameType.Separator;
        }
    }

    static string buildId(const string fragment, const string suffix, const char separator)
    {
        string id = fragment ~ suffix;
        if (separator != 0)
        {
            id ~= separator;
        }
        return id.toLower();
    }

    void processWord(const string fragment, const char c)
    {
        this.activePart.name ~= fragment;
        if (c.isDigit)
        {
            this.activePart.type = NameType.WordNumber;
        } else if (!c.isRoman || !this.recognizeRoman)
        {
            if (!this.mergePart(this.activePart, "", c))
            {
                auto id = this.buildId(this.activePart.name, "", c);
                this.activeParent[id] = this.activePart;
                if (this.activePart.type == NameType.Unknown)
                {
                    this.activePart.type = NameType.Word;
                }
            }
        }
    }

    void processNumber(const string fragment, const char c)
    {
        auto suffix = "%d";
        if (c.isWord)
        {
            this.activePart.name ~= suffix;
            this.activePart.type = NameType.WordNumber;
        } else
        {
            if (!this.mergePart(this.activePart, suffix, c))
            {
                auto id = this.buildId(this.activePart.name, suffix, c);
                this.activePart.name ~= suffix;
                this.activeParent[id] = this.activePart;
                if (this.activePart.type == NameType.Unknown)
                {
                    this.activePart.type = NameType.Number;
                } else
                {
                    this.activePart.type = NameType.WordNumber;
                }
            }
        }
        this.activePart.addSibling(fragment);
    }

    void processRoman(string fragment, const char c)
    {
        if (c.isWord)
        {
            this.activePart.name ~= fragment;
        } else if (c.isDigit)
        {
            this.processWord(fragment, c);
        } else
        {
            auto suffix = "%r";
            auto activeType = NameType.RomanNumber;
            // if it's too long it's most likely not a roman numeral
            bool considerRoman = fragment.length <= 7;
            if (!this.activePart.name.empty && this.activePart.name.length <= 2)
            {
                // too short for roman use
                considerRoman = false;
            }
            else if (considerRoman && !this.activePart.name.empty)
            {
                long romanPosition = -1;
                // allow words to end only with small roman numerals
                foreach_reverse (index, numeral; fragment)
                {
                    if (!isSmallRoman(numeral))
                    {
                        romanPosition = index;
                        break;
                    }
                }
                if (romanPosition == fragment.length - 1)
                {
                    considerRoman = false;
                } else if (romanPosition != -1)
                {
                    this.activePart.name ~= fragment[0..romanPosition + 1];
                    fragment = fragment[romanPosition + 1..$];
                }
            } else if (considerRoman && fragment.length == 1 && !fragment[0].isSmallRoman)
            {
                // allow only small roman numerals to be short
                considerRoman = false;
            }
            if (considerRoman && fromRoman(fragment) == 0)
            {
                // invalid combination
                considerRoman = false;
            }
            if (!considerRoman)
            {
                this.activePart.name ~= fragment;
                fragment = "";
                suffix = "";
                activeType = NameType.Word;
            }
            if (!this.mergePart(this.activePart, suffix, c))
            {
                auto id = this.buildId(this.activePart.name, suffix, c);
                this.activePart.name ~= suffix;
                this.activeParent[id] = this.activePart;
                if (this.activePart.type == NameType.Unknown)
                {
                    this.activePart.type = activeType;
                } else if (activeType == NameType.RomanNumber)
                {
                    this.activePart.type = NameType.WordRomanNumber;
                }
            }
            if (!fragment.empty)
            {
                this.activePart.addSibling(fragment);
            }
        }
    }

    void processSeparator(const string fragment)
    {
        this.activePart.addSeparator(fragment);
        this.activeParent = this.activePart.childs;
        this.activePart = new NamePart();
    }

    bool mergePart(NamePart namePart, string suffix, const char c)
    {
        string sibling;
        auto found = false;
        auto id = this.buildId(namePart.name, suffix, c);
        if (id in this.activeParent)
        {
            found = true;
        } else
        {
            bool hasSuffix = !suffix.empty;
            if (namePart.name.empty)
            {
                return false;
            } else if (namePart.name.length == 1 && !hasSuffix)
            {
                return false;
            }

            assert(namePart.separators.empty);
            assert(namePart.childs.empty);

            suffix = "%c";
            string name = namePart.name;
            string chopped;

            if (hasSuffix)
            {
                chopped = namePart.name;
            } else
            {
                assert(namePart.type != NameType.WordNumber || name.length > 2);
                chopped = name.chop;
                sibling = name.back.to!string;
            }

            id = this.buildId(chopped, suffix, c);
            if (id in this.activeParent)
            {
                name = chopped;
                found = true;
            } else if (!hasSuffix && name.length >= 3 &&
              (namePart.type != NameType.WordNumber || chopped[$-2..$] != "%d"))
            {
                chopped = chopped.chop;
                sibling = name[$-2..$];
                id = this.buildId(chopped, suffix, c);
                if (id in this.activeParent)
                {
                    name = chopped;
                    found = true;
                }
            }

            if (!found)
            {
                foreach (otherId, otherPart; this.activeParent)
                {
                    auto baseName = otherPart.baseName;
                    long fullDiff = otherPart.name.length - chopped.length;
                    if (sibling.length == 2 && fullDiff > 1 && baseName.startsWith(chopped ~ sibling[0]))
                    {
                        fullDiff--;
                    }
                    if (name != otherPart.name && fullDiff >= 1 && fullDiff <= 2 && otherPart.name.startsWith(chopped))
                    {
                        if (otherPart.separators.empty && c != 0)
                        {
                            continue;
                        }
                        if (fullDiff < otherPart.name.length - chopped.length)
                        {
                            chopped = name.chop;
                            sibling = sibling[1..$];
                            id = this.buildId(chopped, suffix, c);
                        }

                        otherPart.addSiblings(namePart.siblings);
                        if (otherPart.type == NameType.WordLetter)
                        {
                            foreach (index, sibling; otherPart.siblings)
                            {
                                otherPart.siblings[index] = baseName[chopped.length..$] ~ sibling;
                            }
                        } else
                        {
                            auto otherSibling = otherPart.name[chopped.length..$];
                            if (otherSibling != "%d" && otherSibling != "%r")
                            {
                                otherPart.addSibling(otherSibling);
                            }
                        }
                        otherPart.name = baseName[0..chopped.length];
                        otherPart.capitaliseName(chopped);
                        otherPart.name ~= suffix;
                        if (!sibling.empty)
                        {
                            otherPart.addSibling(sibling);
                        }
                        if (otherPart.type == NameType.WordNumber && otherPart.name.canFind("%d"))
                        {
                            otherPart.type = NameType.WordNumberLetter;
                        } else
                        {
                            otherPart.type = NameType.WordLetter;
                        }
                        if (c != 0)
                        {
                            otherPart.addSeparator(c.to!string);
                        }
                        this.activePart = otherPart;
                        this.activeParent[id] = this.activePart;
                        this.activeParent.remove(otherId);
                        return true;
                    }
                }
            }
        }

        if (found)
        {
            this.activePart = this.activeParent[id];
            this.activePart.capitaliseName(this.activePart.name ~ suffix);
            if (!sibling.empty)
            {
                this.activePart.addSibling(sibling);
            }
            return true;
        }
        return false;
    }


private:
    NamePart activePart;
    NameType activeType;
    NamePart[string] activeParent;
    ulong fragmentStart;
    bool recognizeRoman;
    uint threads;
}

void outputMatch(const uint hash, const char[] name, bool flush = true)
{
    stdout.writefln("%d:%s", hash, name);
    if (flush)
    {
        stdout.flush();
    }
}

void outputMatch(const ulong hash, const char[] name, bool flush = true)
{
    stdout.writefln("%016x:%s", hash, name);
    if (flush)
    {
        stdout.flush();
    }
}

void filterHashes(ref Hashes hashes, const string[] names, bool output)
{
    foreach (name; names)
    {
        auto lowerName = name.toLower();
        ulong index;
        if (hashes.enable32bit)
        {
            uint hash32 = fnvHash32(InitialFNV32, lowerName);
            index = hashes.fnv32.lowerBound(hash32).length;
            if (index < hashes.fnv32.length && hashes.fnv32[index] == hash32)
            {
                hashes.fnv32 = hashes.fnv32.remove(index);
                if (output)
                {
                    outputMatch(hash32, name, false);
                }
            }
        } else
        {
            ulong hash64 = fnvHash64(InitialFNV64, lowerName);
            index = hashes.fnv64.lowerBound(hash64).length;
            if (index < hashes.fnv64.length && hashes.fnv64[index] == hash64)
            {
                hashes.fnv64 = hashes.fnv64.remove(index);
                if (output)
                {
                    outputMatch(hash64, name, false);
                }
            }
        }
    }
}

int main(string[] args)
{

    int threads = 0;
    int expand = -1;
    bool filter = false;
    bool onlyNew = false;
    bool printPatterns = false;
    bool printGenerated = false;
    bool printJSON = false;
    bool enableRoman = false;
    bool enable32bit = false;
    GetoptResult options;

    try
    {
        options = getopt(args,
                          "filter|f", "Filter provided names, listing ones that matched hashes", &filter,
                          "patterns|p", "Show name patterns", &printPatterns,
                          "generated|g", "List all generated names", &printGenerated,
                          "json|j", "Show internal raw info in JSON", &printJSON,
                          "expand|e", "Increase name search by this amount (default 5)", &expand,
                          "new|n", "List only new names without those that already matched", &onlyNew,
                          "roman|r", "Recognize Roman Numerals", &enableRoman,
                          "32bit|b", "Look for names for 32-bit FNV-1 hashes", &enable32bit,
                          "threads|t", "Number of threads to use (default number of CPU cores)", &threads
        );
    } catch (GetOptException e)
    {
        stderr.writeln(e.message);
        return 1;
    }

    if (filter && expand > 0)
    {
        stderr.writeln("Can't specify --filter and --expand at same time because they are mutually exclusive!");
        return 1;
    }

    if (filter && onlyNew)
    {
        stderr.writeln("Can't specify --filter and --new at same time because they are mutually exclusive!");
        return 1;
    }

    if (expand < 0)
    {
        expand = 5;
    }

    bool hasHashes = true;
    if (printPatterns || printGenerated || printJSON)
    {
        hasHashes = false;
        if (filter)
        {
            stderr.writeln("--filter is incompatible with these options!");
            return 1;
        }
    }

    if (options.helpWanted || args.length < (hasHashes ? 3 : 2))
    {
        auto writer = options.helpWanted ? stdout.lockingTextWriter : stderr.lockingTextWriter;
        defaultGetoptFormatter(writer, "Usage: " ~ args[0] ~ " [options] [hashes.txt] names.txt [names2.txt ...]", options.options);
        return options.helpWanted ? 0 : 1;
    }

    if (threads <= 0)
    {
        threads = totalCPUs;
    }
    defaultPoolThreads(threads);
    stderr.writefln("Using %d threads", threads);

    uint namesArgIndex = 1;
    Hashes hashes;
    if (hasHashes)
    {
        hashes = loadHashes(args[namesArgIndex++]);
        if (!hashes.fnv32.empty && hashes.fnv64.empty)
        {
            enable32bit = true;
        }
        if (enable32bit)
        {
            stderr.writefln("Loaded %d FNV-1 32-bit hashes", hashes.fnv32.length);
            if (!hashes.fnv64.empty)
            {
                stderr.writefln("Ignoring %d FNV-1 64-bit hashes", hashes.fnv64.length);
            }
        } else
        {
            if (!hashes.fnv32.empty)
            {
                stderr.writefln("Ignoring %d FNV-1 32-bit hashes", hashes.fnv32.length);
            }
            stderr.writefln("Loaded %d FNV-1 64-bit hashes", hashes.fnv64.length);
        }
    }
    hashes.enable32bit = enable32bit;

    auto names = loadNames(args[namesArgIndex..$]);
    stderr.writefln("Loaded %d unique names", names.length);

    auto forestBuilder = new NameForestBuilder(threads, enableRoman);
    if (!filter)
    {
        stderr.writeln("Categorizing names...");
        forestBuilder.processAll(names);

        stderr.writeln("Merging names...");
        forestBuilder.merge();

        if (printPatterns)
        {
            ulong patternCount = 0;
            foreach(pattern; forestBuilder.toPatterns())
            {
                auto values = (pattern.values.to!(string[])).join("");
                if (values.empty)
                {
                    writeln(pattern.pattern);
                } else
                {
                    writefln("%s:%s", pattern.pattern, values);
                }
                patternCount++;
            }
            stderr.writefln("Found %d patterns", patternCount);
            return 0;
        }

        stderr.writeln("Generating potential names...");
        forestBuilder.expand(expand);

        if (printJSON)
        {
            writeln(forestBuilder.toJSON(true));
            return 0;
        }

        stderr.writefln("Generated %d names", forestBuilder.combinations);

        if (printGenerated)
        {
            stderr.writeln("Listing names...");
            forestBuilder.listNames(name => writeln(name));
            stderr.writeln("Done! :)");
            return 0;
        }
    }

    if (onlyNew || filter)
    {
        stderr.writefln("Filtering hashes...", names.length);
        auto before32 = hashes.fnv32.length;
        auto before64 = hashes.fnv64.length;
        filterHashes(hashes, names, filter);
        if (enable32bit)
        {
            stderr.writefln("%d FNV-1 32-bit hashes matched, remaining %d hashes to crack", before32 - hashes.fnv32.length, hashes.fnv32.length);
        } else
        {
            stderr.writefln("%d FNV-1 64-bit hashes matched, remaining %d hashes to crack", before64 - hashes.fnv64.length, hashes.fnv64.length);
        }
        if (filter)
        {
            return 0;
        }
    }

    if ((!enable32bit && hashes.fnv64.empty) || (enable32bit && hashes.fnv32.empty))
    {
        stderr.writefln("All hashes have already been cracked :)");
        return 0;
    }

    stderr.writeln("Cracking names...");
    uint[] found32;
    ulong[] found64;
    forestBuilder.findNames(hashes, (auto nameInfo, bool is32bit)
    {
        string name = nameInfo.name[0..nameInfo.nameLength].to!string;
        if (is32bit)
        {
            outputMatch(nameInfo.fnv32, name, true);
            synchronized
            {
                found32 ~= nameInfo.fnv32;
            }
        } else
        {
            outputMatch(nameInfo.fnv64, name, true);
            synchronized
            {
                found64 ~= nameInfo.fnv64;
            }
        }
    });

    stderr.writeln("Finished cracking names! :)");
    string namesStr = "names";
    if (onlyNew)
    {
        namesStr = "new " ~ namesStr;
    }
    if (enable32bit)
    {
        found32.length -= found32.sort.uniq.copy(found32).length;
        if (found32.length < hashes.fnv32.length)
        {
            stderr.writefln("Found %d %s for FNV-1 32-bit hashes, couldn't find %d names .-.", found32.length, namesStr, hashes.fnv32.length - found32.length);
        } else
        {
            stderr.writefln("Found %d %s for FNV-1 32-bit hashes. All names have been found! :)", found32.length, namesStr);
        }
    } else
    {
        found64.length -= found64.sort.uniq.copy(found64).length;
        if (found64.length < hashes.fnv64.length)
        {
            stderr.writefln("Found %d %s for FNV-1 64-bit hashes, couldn't find %d names .-.", found64.length, namesStr, hashes.fnv64.length - found64.length);
        } else
        {
            stderr.writefln("Found %d %s for FNV-1 64-bit hashes. All names have been found! :)", found64.length, namesStr);
        }
    }
    return 0;
}
