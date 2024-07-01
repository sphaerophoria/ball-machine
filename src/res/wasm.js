function logWasm(module, s, len) {
  var uint_arr = new Uint8Array(module.instance.exports.memory.buffer, s, len);
  var dec = new TextDecoder();
  const str = dec.decode(uint_arr);
  console.log(str);
}

export async function makeChamber(url) {
  const chamber = {};
  const chamberImport = {
    env: { logWasm: (...args) => logWasm(chamber.item, ...args) },
  };

  chamber.item = await WebAssembly.instantiateStreaming(
    fetch(url),
    chamberImport,
  );

  return chamber.item;
}
