# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[hashes, os, sequtils],
  eth/common,
  rocksdb,
  ../../nimbus/db/aristo/[
    aristo_debug, aristo_desc, aristo_delete, aristo_filter/filter_scheduler,
    aristo_hashify, aristo_hike, aristo_merge],
  ../../nimbus/db/kvstore_rocksdb,
  ../../nimbus/sync/protocol/snap/snap_types,
  ../test_sync_snap/test_types,
  ../replay/[pp, undump_accounts, undump_storages]

from ../../nimbus/sync/snap/range_desc
  import NodeKey, ByteArray32

type
  ProofTrieData* = object
    root*: Hash256
    id*: int
    proof*: seq[SnapProof]
    kvpLst*: seq[LeafTiePayload]

const
  samples = [
    [      (4,0,10),      (3,3,10),      (3,4,10),      (3,5,10)],
    [(2,0,high int),(1,1,high int),(1,1,high int),(1,1,high int)],
  ]

  LyoSamples* = samples.mapIt((it, (3 * it.capacity.minCovered) div 2))

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func toPfx(indent: int): string =
  "\n" & " ".repeat(indent)

func to(a: NodeKey; T: type UInt256): T =
  T.fromBytesBE ByteArray32(a)

func to(a: NodeKey; T: type PathID): T =
  a.to(UInt256).to(T)

# ------------------------------------------------------------------------------
# Public pretty printing
# ------------------------------------------------------------------------------

func pp*(
    w: ProofTrieData;
    rootID: VertexID;
    db: AristoDbRef;
    indent = 4;
      ): string =
  let
    pfx = indent.toPfx
    rootLink = w.root.to(HashKey)
  result = "(" & rootLink.pp(db)
  result &= "," & $w.id & ",[" & $w.proof.len & "],"
  result &= pfx & " ["
  for n,kvp in w.kvpLst:
    if 0 < n:
      result &= "," & pfx & "  "
    result &= "(" & kvp.leafTie.pp(db) & "," & $kvp.payload.pType & ")"
  result &= "])"

proc pp*(w: ProofTrieData; indent = 4): string =
  var db = AristoDbRef()
  w.pp(VertexID(1), db, indent)

proc pp*(
    w: openArray[ProofTrieData];
    rootID: VertexID;
    db: AristoDbRef;
    indent = 4): string =
  let pfx = indent.toPfx
  "[" & w.mapIt(it.pp(rootID, db, indent + 1)).join("," & pfx & " ") & "]"

proc pp*(w: openArray[ProofTrieData]; indent = 4): string =
  let pfx = indent.toPfx
  "[" & w.mapIt(it.pp(indent + 1)).join("," & pfx & " ") & "]"

proc pp*(ltp: LeafTiePayload; db: AristoDbRef): string =
  "(" & ltp.leafTie.pp(db) & "," & ltp.payload.pp(db) & ")"

# ----------

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func `==`*[T: AristoError|VertexID](a: T, b: int): bool =
  a == T(b)

func `==`*(a: (VertexID|QueueID,AristoError), b: (int,int)): bool =
  (a[0].int,a[1].int) == b

func `==`*(a: (VertexID,AristoError), b: (int,AristoError)): bool =
  (a[0].int,a[1]) == b

func `==`*(a: (int,AristoError), b: (int,int)): bool =
  (a[0],a[1].int) == b

func `==`*(a: (int,VertexID,AristoError), b: (int,int,int)): bool =
  (a[0], a[1].int, a[2].int) == b

func `==`*(a: (QueueID,Hash), b: (int,Hash)): bool =
  (a[0].int,a[1]) == b

func to*(a: Hash256; T: type UInt256): T =
  T.fromBytesBE a.data

func to*(a: Hash256; T: type PathID): T =
  a.to(UInt256).to(T)

func to*(a: HashKey; T: type UInt256): T =
  T.fromBytesBE 0u8.repeat(32 - a.len) & @a

func to*(fid: FilterID; T: type Hash256): T =
  result.data = fid.uint64.u256.toBytesBE

proc to*(sample: AccountsSample; T: type seq[UndumpAccounts]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
  var root: Hash256
  for w in file.undumpNextAccount:
    let n = w.seenAccounts - 1
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc to*(sample: AccountsSample; T: type seq[UndumpStorages]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
  var root: Hash256
  for w in file.undumpNextStorages:
    let n = w.seenAccounts - 1 # storages selector based on accounts
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

func to*(ua: seq[UndumpAccounts]; T: type seq[ProofTrieData]): T =
  var (rootKey, rootVid) = (Hash256(), VertexID(0))
  for w in ua:
    let thisRoot = w.root
    if rootKey != thisRoot:
      (rootKey, rootVid) = (thisRoot, VertexID(rootVid.uint64 + 1))
    if 0 < w.data.accounts.len:
      result.add ProofTrieData(
        root:   rootKey,
        proof:  w.data.proof,
        kvpLst: w.data.accounts.mapIt(LeafTiePayload(
          leafTie: LeafTie(
            root:  rootVid,
            path:  it.accKey.to(PathID)),
          payload: PayloadRef(pType: RawData, rawBlob: it.accBlob))))

func to*(us: seq[UndumpStorages]; T: type seq[ProofTrieData]): T =
  var (rootKey, rootVid) = (Hash256(), VertexID(0))
  for n,s in us:
    for w in s.data.storages:
      let thisRoot = w.account.storageRoot
      if rootKey != thisRoot:
        (rootKey, rootVid) = (thisRoot, VertexID(rootVid.uint64 + 1))
      if 0 < w.data.len:
        result.add ProofTrieData(
          root:   thisRoot,
          id:     n + 1,
          kvpLst: w.data.mapIt(LeafTiePayload(
            leafTie: LeafTie(
              root:  rootVid,
              path:  it.slotHash.to(PathID)),
            payload: PayloadRef(pType: RawData, rawBlob: it.slotData))))
    if 0 < result.len:
      result[^1].proof = s.data.proof

func mapRootVid*(
    a: openArray[LeafTiePayload];
    toVid: VertexID;
      ): seq[LeafTiePayload] =
  a.mapIt(LeafTiePayload(
    leafTie: LeafTie(root: toVid, path: it.leafTie.path),
    payload: it.payload))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hashify*(
    db: AristoDbRef;
    noisy: bool;
      ): Result[void,(VertexID,AristoError)] =
  when declared(aristo_hashify.noisy):
    aristo_hashify.exec(noisy, aristo_hashify.hashify(db))
  else:
    aristo_hashify.hashify(db)


proc delete*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
    accPath: PathID;
    noisy: bool;
      ): Result[bool,(VertexID,AristoError)] =
  when declared(aristo_delete.noisy):
    aristo_delete.exec(noisy, aristo_delete.delete(db, root, path, accPath))
  else:
    aristo_delete.delete(db, root, path, accPath)

proc delete*(
    db: AristoDbRef;
    lty: LeafTie;
    accPath: PathID;
    noisy: bool;
      ): Result[bool,(VertexID,AristoError)] =
  when declared(aristo_delete.noisy):
    aristo_delete.exec(noisy, aristo_delete.delete(db, lty, accPath))
  else:
    aristo_delete.delete(db, lty, accPath)

proc delTree*(
    db: AristoDbRef;
    root: VertexID;
    accPath: PathID;
    noisy: bool;
      ): Result[void,(VertexID,AristoError)] =
  when declared(aristo_delete.noisy):
    aristo_delete.exec(noisy, aristo_delete.delTree(db, root, accPath))
  else:
    aristo_delete.delTree(db, root, accPath)


proc merge*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
    data: openArray[byte];
    accPath: PathID;
    noisy: bool;
      ): Result[bool, AristoError] =
  when declared(aristo_merge.noisy):
    aristo_merge.exec(noisy, aristo_merge.merge(db, root, path, data, accPath))
  else:
    aristo_merge.merge(db, root, path, data, accPath)

proc mergePayload*(
    db: AristoDbRef;
    lty: LeafTie;
    pyl: PayloadRef;
    accPath: PathID;
    noisy: bool;
      ): Result[Hike,AristoError] =
  when declared(aristo_merge.noisy):
    aristo_merge.exec(noisy, aristo_merge.mergePayload(db, lty, pyl, accPath))
  else:
    aristo_merge.mergePayload(db, lty, pyl, accPath)


proc mergeList*(
    db: AristoDbRef;                   # Database, top layer
    leafs: openArray[LeafTiePayload];  # Leaf items to add to the database
    noisy = false;
      ): tuple[merged: int, dups: int, error: AristoError] =
  ## Variant of `merge()` for leaf lists.
  var (merged, dups) = (0, 0)
  for n,w in leafs:
    noisy.say "*** mergeList",
      " n=", n, "/", leafs.len
    let rc = db.mergePayload(w.leafTie, w.payload, VOID_PATH_ID, noisy=noisy)
    noisy.say "*** mergeList",
      " n=", n, "/", leafs.len,
      " rc=", (if rc.isOk: "ok" else: $rc.error),
      "\n    -------------\n"
    if rc.isOk:
      merged.inc
    elif rc.error in {MergeLeafPathCachedAlready,MergeLeafPathOnBackendAlready}:
      dups.inc
    else:
      return (n,dups,rc.error)

  (merged, dups, AristoError(0))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
