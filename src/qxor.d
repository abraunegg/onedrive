import std.algorithm;
import std.digest;

// implementation of the QuickXorHash algorithm in D
// https://github.com/OneDrive/onedrive-api-docs/blob/live/docs/code-snippets/quickxorhash.md
struct QuickXor
{
	private immutable int widthInBits = 160;
	private immutable size_t lengthInBytes = (widthInBits - 1) / 8 + 1;
	private immutable size_t lengthInQWords = (widthInBits - 1) / 64 + 1;
	private immutable int bitsInLastCell = widthInBits % 64; // 32
	private immutable int shift = 11;

	private ulong[lengthInQWords] _data;
	private ulong _lengthSoFar;
	private int _shiftSoFar;

	nothrow @safe void put(scope const(ubyte)[] array...)
	{
		int vectorArrayIndex = _shiftSoFar / 64;
		int vectorOffset = _shiftSoFar % 64;
		immutable size_t iterations = min(array.length, widthInBits);

		for (size_t i = 0; i < iterations; i++) {
			immutable bool isLastCell = vectorArrayIndex == _data.length - 1;
			immutable int bitsInVectorCell = isLastCell ? bitsInLastCell : 64;

			if (vectorOffset <= bitsInVectorCell - 8) {
				 for (size_t j = i; j < array.length; j += widthInBits) {
					_data[vectorArrayIndex] ^= cast(ulong) array[j] << vectorOffset;
				 }
			} else {
				int index1 = vectorArrayIndex;
				int index2 = isLastCell ? 0 : (vectorArrayIndex + 1);
				ubyte low = cast(ubyte) (bitsInVectorCell - vectorOffset);

				ubyte xoredByte = 0;
				for (size_t j = i; j < array.length; j += widthInBits) {
					xoredByte ^= array[j];
				}

				_data[index1] ^= cast(ulong) xoredByte << vectorOffset;
				_data[index2] ^= cast(ulong) xoredByte >> low;
			}

			vectorOffset += shift;
			if (vectorOffset >= bitsInVectorCell) {
				vectorArrayIndex = isLastCell ? 0 : vectorArrayIndex + 1;
				vectorOffset -= bitsInVectorCell;
			}
		}

		_shiftSoFar = cast(int) (_shiftSoFar + shift * (array.length % widthInBits)) % widthInBits;
		_lengthSoFar += array.length;

	}

	nothrow @safe void start()
	{
		_data = _data.init;
		_shiftSoFar = 0;
		_lengthSoFar = 0;
	}

	nothrow @trusted ubyte[lengthInBytes] finish()
	{
		ubyte[lengthInBytes] tmp;
		tmp[0 .. lengthInBytes] = (cast(ubyte*) _data)[0 .. lengthInBytes];
		for (size_t i = 0; i < 8; i++) {
			tmp[lengthInBytes - 8 + i] ^= (cast(ubyte*) &_lengthSoFar)[i];
        }
		return tmp;
	}
}

unittest
{
	assert(isDigest!QuickXor);
}

unittest
{
	QuickXor qxor;
	qxor.put(cast(ubyte[]) "The quick brown fox jumps over the lazy dog");
	assert(qxor.finish().toHexString() == "6CC4A56F2B26C492FA4BBE57C1F31C4193A972BE");
}

alias QuickXorDigest = WrapperDigest!(QuickXor);
