### Largest on average tree contexts
---

In the return statement of this function in `brotli-decompressor`, we create a lookup table for huffman trees (`&[HuffmanCode]`), up to 256 items:

```rs
pub fn build_hgroup_cache(&self) -> [&[HuffmanCode]; 256] {
      let mut ret : [&[HuffmanCode]; 256] = [&[]; 256];
      let mut index : usize = 0;
      for htree in self.htrees.slice() {
          ret[index] = fast_slice!((&self.codes)[*htree as usize ; ]);
          index += 1;
      }
      ret
    }
```