/*******************************************************************************

    Variadic-sized value type to represent a hash

    A `BitBlob` is a value type representing a hash.
    The argument is the size in bits, e.g. for sha256 it is 256.
    It can be initialized from the hexadecimal string representation
    or an `ubyte[]`, making it easy to interact with `std.digest`

    Author:         Mathias 'Geod24' Lang
    License:        MIT (See LICENSE.txt)
    Copyright:      Copyright (c) 2017-2018 Mathias Lang. All rights reserved.

*******************************************************************************/

module geod24.bitblob;

static import std.ascii;
import std.algorithm.iteration : each, map;
import std.algorithm.searching : countUntil, startsWith;
import std.format;
import std.range;
import std.utf;

///
@nogc @safe pure nothrow unittest
{
    /// Alias for a 256 bits / 32 byte hash type
    alias Hash = BitBlob!32;

    import std.digest.sha;
    // Can be initialized from an `ubyte[32]`
    // (or `ubyte[]` of length 32)
    Hash fromSha = sha256Of("Hello World");

    // Of from a string
    Hash genesis = GenesisBlockHashStr;

    assert(!genesis.isNull());
    assert(Hash.init.isNull());

    ubyte[5] empty;
    assert(Hash.init < genesis);
    // The underlying 32 bytes can be access through `opIndex` and `opSlice`
    assert(genesis[$ - 5 .. $] == empty);
}


/*******************************************************************************

    A value type representing a large binary value

    Params:
      Size = The size of the hash, in bytes

*******************************************************************************/

public struct BitBlob (size_t Size)
{
    @safe:

    /// Convenience enum
    public enum StringBufferSize = (Size * 2 + 2);

    /***************************************************************************

        Format the hash as a lowercase hex string

        Used by `std.format` and other formatting primitives.
        Does not allocate/throw if the sink does not allocate/throw.

        See_Also:
          https://issues.dlang.org/show_bug.cgi?id=21722

        Params:
          sink = A delegate that can be called repeatedly to accumulate the data
          spec = The format spec to be used for the hex string representation.
                 's' (which is default) - 0x prefix and lowercase hex
                 'X' : uppercase hex
                 'x' : lowercase hex


    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) @safe sink) const
    {
        FormatSpec!char spec;
        this.toString(sink, spec);
    }

    /// Ditto
    public void toString (scope void delegate(const(char)[]) @safe sink,
                          scope const ref FormatSpec!char spec) const
    {
        /// Used for formatting
        static immutable LHexDigits = `0123456789abcdef`;
        static immutable HHexDigits = `0123456789ABCDEF`;

        void formatDigits (immutable string hex_digits)
        {
            char[2] data;
            // retro because the data is stored in little endian
            this.data[].retro.each!(
                (bin)
                {
                    data[0] = hex_digits[bin >> 4];
                    data[1] = hex_digits[(bin & 0b0000_1111)];
                    sink(data);
                });
        }

        switch (spec.spec)
        {
        case 'X':
            formatDigits(HHexDigits);
            break;
        case 's':
        default:
            sink("0x");
            goto case;
        case 'x':
            formatDigits(LHexDigits);
            break;
        }
    }

    /***************************************************************************

        Get the string representation of this hash

        Only performs one allocation.

    ***************************************************************************/

    public string toString () const
    {
        size_t idx;
        char[StringBufferSize] buffer = void;
        scope sink = (const(char)[] v) {
                buffer[idx .. idx + v.length] = v;
                idx += v.length;
            };
        this.toString(sink);
        return buffer.idup;
    }

    /***************************************************************************

        Support deserialization

        Vibe.d expects the `toString`/`fromString` to be present for it to
        correctly serialize and deserialize a type.
        This allows to use this type as parameter in `vibe.web.rest` methods,
        or use it with Vibe.d's serialization module.
        This function does more extensive validation of the input than the
        constructor and can be given user input.

    ***************************************************************************/

    static auto fromString (scope const(char)[] str)
    {
        // Ignore prefix
        if (str.startsWith("0x") || str.startsWith("0X"))
            str = str[2 .. $];

        // Then check length
        if (str.length != Size * 2)
            throw new Exception(
                format("Cannot parse string '%s' of length %s: Expected %s chars (%s with prefix)",
                       str, str.length, Size * 2, Size * 2 + 2));

        // Then content check
        auto index = str.countUntil!(e => !std.ascii.isAlphaNum(e));
        if (index != -1)
            throw new Exception(
                format("String '%s' has non alphanumeric character at index %s",
                       str, index));

        return BitBlob(str);
    }

    pure nothrow @nogc:

    /***************************************************************************

        Create a BitBlob from binary data, e.g. serialized data

        Params:
            bin  = Binary data to store in this `BitBlob`.
            isLE = `true` if the data is little endian, `false` otherwise.
                   Internally the data will be stored in little endian.

        Throws:
            If `bin.length != typeof(this).sizeof`

    ***************************************************************************/

    public this (scope const ubyte[] bin, bool isLE = true)
    {
        enum W = Size; // Make sure the value is shown, not the symbol
        if (bin.length != Size)
            assert(0, "ubyte[] argument to " ~ typeof(this).stringof
                   ~ " constructor does not match the expected size of "
                   ~ W.stringof);

        this.data[] = bin[];
        if (!isLE)
        {
            foreach (cnt; 0 .. Size / 2)
            {
                // Not sure the frontend is clever enough to avoid bounds checks
                this.data[cnt] ^= this.data[$ - 1 - cnt];
                this.data[$ - 1 - cnt] ^= this.data[cnt];
                this.data[cnt] ^= this.data[$ - 1 - cnt];
            }
        }
    }

    /***************************************************************************

        Create a BitBlob from an hexadecimal string representation

        Params:
            hexstr = String representation of the binary data in base 16.
                     The hexadecimal prefix (0x) is optional.
                     Can be upper or lower case.

        Throws:
            If `hexstr_without_prefix.length != (typeof(this).sizeof * 2)`.

    ***************************************************************************/

    public this (scope const(char)[] hexstr)
    {
        enum Expected = Size * 2; // Make sure the value is shown, not the symbol
        enum ErrorMsg = "Length of string passed to " ~ typeof(this).stringof
            ~ " constructor does not match the expected size of " ~ Expected.stringof;
        if (hexstr.length == (Expected + "0x".length))
        {
            assert(hexstr[0] == '0', ErrorMsg);
            assert(hexstr[1] == 'x' || hexstr[1] == 'X', ErrorMsg);
            hexstr = hexstr[2 .. $];
        }
        else
            assert(hexstr.length == Expected, ErrorMsg);

        auto range = hexstr.byChar.map!(std.ascii.toLower!(char));
        size_t idx;
        foreach (chunk; range.map!(fromHex).chunks(2).retro)
            this.data[idx++] = cast(ubyte)((chunk[0] << 4) + chunk[1]);
    }

    /// Store the internal data
    private ubyte[Size] data;

    /// Returns: If this BitBlob has any value
    public bool isNull () const
    {
        return this == typeof(this).init;
    }

    /// Used for sha256Of
    public inout(ubyte)[] opIndex () inout
    {
        return this.data;
    }

    /// Convenience overload
    public inout(ubyte)[] opSlice (size_t from, size_t to) inout
    {
        return this.data[from .. to];
    }

    /// Ditto
    alias opDollar = Size;

    /// Public because of a visibility bug
    public static ubyte fromHex (char c)
    {
        if (c >= '0' && c <= '9')
            return cast(ubyte)(c - '0');
        if (c >= 'a' && c <= 'f')
            return cast(ubyte)(10 + c - 'a');
        assert(0, "Unexpected char in string passed to BitBlob");
    }

    /// Support for comparison
    public int opCmp (ref const typeof(this) s) const
    {
        // Reverse because little endian
        foreach_reverse (idx, b; this.data)
            if (b != s.data[idx])
                return b - s.data[idx];
        return 0;
    }

    /// Support for comparison (rvalue overload)
    public int opCmp (const typeof(this) s) const
    {
        return this.opCmp(s);
    }
}

pure @safe nothrow @nogc unittest
{
    alias Hash = BitBlob!32;

    Hash gen1 = GenesisBlockHashStr;
    Hash gen2 = GenesisBlockHash;
    assert(gen1.data == GenesisBlockHash);
    assert(gen1 == gen2);

    Hash gm1 = GMerkle_str;
    Hash gm2 = GMerkle_bin;
    assert(gm1.data == GMerkle_bin);
    // Test opIndex
    assert(gm1[] == GMerkle_bin);
    assert(gm1 == gm2);

    Hash empty;
    assert(empty.isNull);
    assert(!gen1.isNull);

    // Test opCmp
    assert(empty < gen1);
    assert(gm1 > gen2);

    assert(!(gm1 > gm1));
    assert(!(gm1 < gm1));
    assert(gm1 >= gm1);
    assert(gm1 <= gm1);
}

/// Test toString
unittest
{
    import std.string : toUpper;

    alias Hash = BitBlob!32;
    Hash gen1 = GenesisBlockHashStr;
    assert(format("%s", gen1) == GenesisBlockHashStr);
    assert(format("%x", gen1) == GenesisBlockHashStr[2 .. $]);
    assert(format("%X", gen1) == GenesisBlockHashStr[2 .. $].toUpper());
    assert(format("%w", gen1) == GenesisBlockHashStr);
    assert(gen1.toString() == GenesisBlockHashStr);
    assert(Hash(gen1.toString()) == gen1);
    assert(Hash.fromString(gen1.toString()) == gen1);
}

/// Make sure `toString` does not allocate even if it's not `@nogc`
unittest
{
    import core.memory;
    alias Hash = BitBlob!32;

    Hash gen1 = GenesisBlockHashStr;
    char[Hash.StringBufferSize] buffer;
    auto statsBefore = GC.stats();
    formattedWrite(buffer[], "%s", gen1);
    auto statsAfter = GC.stats();
    assert(buffer == GenesisBlockHashStr);
    assert(statsBefore.usedSize == statsAfter.usedSize);
}

/// Test initialization from big endian
@safe unittest
{
    import std.algorithm.mutation : reverse;
    ubyte[32] genesis = GenesisBlockHash;
    genesis[].reverse;
    auto h = BitBlob!(32)(genesis, false);
    assert(h.toString() == GenesisBlockHashStr);
}

// Test assertion failure to raise code coverage
unittest
{
    import core.exception : AssertError;
    import std.algorithm.mutation : reverse;
    import std.exception;
    alias Hash = BitBlob!(32);
    ubyte[32] genesis = GenesisBlockHash;
    genesis[].reverse;
    Hash result;
    assert(collectException!AssertError(Hash(genesis[0 .. $ - 1], false)) !is null);
}

// Ditto
unittest
{
    import core.exception : AssertError;
    import std.algorithm.mutation : reverse;
    import std.exception;
    alias Hash = BitBlob!(32);
    ubyte[32] genesis = GenesisBlockHash;
    genesis[].reverse;
    Hash h = Hash(genesis, false);
    Hash h1 = Hash(h.toString());
    assert(h == h1);
    assert(collectException!AssertError(Hash(h.toString()[0 .. $ - 1])) !is null);
}

// Ditto (Covers the assert(0) in `fromHex`)
unittest
{
    alias Hash = BitBlob!(32);
    import core.exception : AssertError;
    import std.exception;
    char[GenesisBlockHashStr.length] buff = GenesisBlockHashStr;
    Hash h = Hash(buff);
    buff[5] = '_'; // Invalid char
    assert(collectException!AssertError(Hash(buff)) !is null);
}

// Test that `fromString` throws Exceptions as and when expected
unittest
{
    import std.exception;
    alias Hash = BitBlob!(32);

    // Error on the length
    assert(collectException!Exception(Hash.fromString("Hello world")) !is null);

    char[GenesisBlockHashStr.length] buff = GenesisBlockHashStr;
    Hash h = Hash(buff);
    buff[5] = '_';
    // Error on the invalid char
    assert(collectException!Exception(Hash.fromString(buff)) !is null);
}

// Make sure the string parsing works at CTFE
unittest
{
    static immutable BitBlob!32 CTFEability = BitBlob!32(GenesisBlockHashStr);
    static assert(CTFEability[] == GenesisBlockHash);
    static assert(CTFEability == BitBlob!32.fromString(GenesisBlockHashStr));
}

// Support for rvalue opCmp
unittest
{
    alias Hash = BitBlob!(32);
    import std.algorithm.sorting : sort;

    static Hash getLValue(int) { return Hash.init; }
    int[] array = [1, 2];
    array.sort!((a, b) => getLValue(a) < getLValue(b));
}

version (unittest)
{
private:
    /// Bitcoin's genesis block hash
    static immutable GenesisBlockHashStr =
        "0x000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f";
    static immutable ubyte[32] GenesisBlockHash = [
        0x6f, 0xe2, 0x8c, 0x0a, 0xb6, 0xf1, 0xb3, 0x72, 0xc1, 0xa6, 0xa2, 0x46,
        0xae, 0x63, 0xf7, 0x4f, 0x93, 0x1e, 0x83, 0x65, 0xe1, 0x5a, 0x08, 0x9c,
        0x68, 0xd6, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00 ];

    /// Bitcoin's genesis block Merkle root hash
    static immutable GMerkle_str =
        "0X4A5E1E4BAAB89F3A32518A88C31BC87F618F76673E2CC77AB2127B7AFDEDA33B";
    static immutable ubyte[] GMerkle_bin = [
        0x3b, 0xa3, 0xed, 0xfd, 0x7a, 0x7b, 0x12, 0xb2, 0x7a, 0xc7, 0x2c, 0x3e,
        0x67, 0x76, 0x8f, 0x61, 0x7f, 0xc8, 0x1b, 0xc3, 0x88, 0x8a, 0x51, 0x32,
        0x3a, 0x9f, 0xb8, 0xaa, 0x4b, 0x1e, 0x5e, 0x4a ];
}
