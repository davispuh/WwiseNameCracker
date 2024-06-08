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

int main(string[] args)
{
}
