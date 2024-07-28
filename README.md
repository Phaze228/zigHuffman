**Compile**

clone the repo,
```
zig build && cp zig-out/bin/zigHuffman ./directory
```


**Usage**

// Encoding
```
./zigHuffman [input file] (optional)[output_file]
```

// Decoding
```
./zigHuffman -d [input_file] (optional)[output_file]
```
**Why**

Huffman Coding is a simple in concept yet mildly more complex to implement than RLE. And I have never implemented a form of compression before.
It may be nice to implement aspects of the DEFLATE algorithm, but the CANONICAL order and transmission of the alphabet in that case, I'm still trying to grok.
