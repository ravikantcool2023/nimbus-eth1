# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/tables,
  eth/common,
  results,
  ../../aristo as use_ari,
  ../../aristo/aristo_walk,
  ../../kvt as use_kvt,
  ../../kvt/[kvt_init/memory_only, kvt_walk],
  ".."/[base, base/base_desc],
  ./aristo_db/[common_desc, handlers_aristo, handlers_kvt, handlers_trace]

import
  ../../aristo/aristo_init/memory_only as aristo_memory_only

# Caveat:
#  additional direct include(s) -- not import(s) -- is placed near
#  the end of this source file

# Annotation helper(s)
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: rlpRaise, gcsafe, raises: [AristoApiRlpError].}

export
  AristoApiRlpError,
  AristoCoreDbKvtBE,
  isAristo

type
  AristoCoreDbRef* = ref object of CoreDbRef
    ## Main descriptor
    kdbBase: KvtBaseRef                      ## Kvt subsystem
    adbBase: AristoBaseRef                   ## Aristo subsystem
    tracer: AristoTracerRef                  ## Currently active recorder

  AristoTracerRef = ref object of TraceRecorderRef
    ## Sub-handle for tracer
    parent: AristoCoreDbRef

proc newAristoVoidCoreDbRef*(): CoreDbRef {.noRaise.}

# ------------------------------------------------------------------------------
# Private tx and base methods
# ------------------------------------------------------------------------------

proc txMethods(
    db: AristoCoreDbRef;
    aTx: AristoTxRef;
    kTx: KvtTxRef;
     ): CoreDbTxFns =
  ## To be constructed by some `CoreDbBaseFns` function
  let
    adbBase = db.adbBase
    kdbBase = db.kdbBase

    adbApi = adbBase.api
    kdbApi = kdbBase.api

  CoreDbTxFns(
    levelFn: proc(): int =
      aTx.level,

    commitFn: proc(ignore: bool): CoreDbRc[void] =
      const info = "commitFn()"
      ? adbApi.commit(aTx).toVoidRc(adbBase, info)
      ? kdbApi.commit(kTx).toVoidRc(kdbBase, info)
      ok(),

    rollbackFn: proc(): CoreDbRc[void] =
      const info = "rollbackFn()"
      ? adbApi.rollback(aTx).toVoidRc(adbBase, info)
      ? kdbApi.rollback(kTx).toVoidRc(kdbBase, info)
      ok(),

    disposeFn: proc(): CoreDbRc[void] =
      const info =  "disposeFn()"
      if adbApi.isTop(aTx): ? adbApi.rollback(aTx).toVoidRc(adbBase, info)
      if kdbApi.isTop(kTx): ? kdbApi.rollback(kTx).toVoidRc(kdbBase, info)
      ok(),

    safeDisposeFn: proc(): CoreDbRc[void] =
      const info =  "safeDisposeFn()"
      if adbApi.isTop(aTx): ? adbApi.rollback(aTx).toVoidRc(adbBase, info)
      if kdbApi.isTop(kTx): ? kdbApi.rollback(kTx).toVoidRc(kdbBase, info)
      ok())

proc cptMethods(
    tracer: AristoTracerRef;
      ): CoreDbCaptFns =
  let
    tr = tracer         # So it can savely be captured
    db = tr.parent      # Will not change and can be captured
    log = tr.topInst()  # Ditto

  CoreDbCaptFns(
    recorderFn: proc(): CoreDbRef =
      db,

    logDbFn: proc(): TableRef[Blob,Blob] =
      log.kLog,

    getFlagsFn: proc(): set[CoreDbCaptFlags] =
      log.flags,

    forgetFn: proc() =
      if not tracer.pop():
        tr.parent.tracer = AristoTracerRef(nil)
        tr.restore())


proc baseMethods(db: AristoCoreDbRef): CoreDbBaseFns =
  let
    aBase = db.adbBase
    kBase = db.kdbBase

  proc tracerSetup(flags: set[CoreDbCaptFlags]): CoreDxCaptRef =
    if db.tracer.isNil:
      db.tracer = AristoTracerRef(parent: db)
      db.tracer.init(kBase, aBase, flags)
    else:
      db.tracer.push(flags)
    CoreDxCaptRef(methods: db.tracer.cptMethods)

  proc persistent(): CoreDbRc[void] =
    const info = "persistentFn()"
    ? aBase.persistent info
    ? kBase.persistent info
    ok()

  CoreDbBaseFns(
    destroyFn: proc(flush: bool) =
      aBase.destroy(flush)
      kBase.destroy(flush),

    levelFn: proc(): int =
      aBase.getLevel,

    colStateFn: proc(col: CoreDbColRef): CoreDbRc[Hash256] =
      aBase.rootHash(col, "rootHashFn()"),

    colPrintFn: proc(vid: CoreDbColRef): string =
      aBase.colPrint(vid),

    errorPrintFn: proc(e: CoreDbErrorRef): string =
      e.errorPrint(),

    legacySetupFn: proc() =
      discard,

    newKvtFn: proc(offSite: bool): CoreDbRc[CoreDxKvtRef] =
      kBase.newKvtHandler(offSite, "newKvtFn()"),

    newCtxFn: proc(): CoreDbCtxRef =
      aBase.ctx,

    newCtxFromTxFn: proc(r: Hash256; k: CoreDbColType): CoreDbRc[CoreDbCtxRef] =
      CoreDbCtxRef.init(db.adbBase, r, k),

    swapCtxFn: proc(ctx: CoreDbCtxRef): CoreDbCtxRef =
      aBase.swapCtx(ctx),

    beginFn: proc(): CoreDbRc[CoreDxTxRef] =
      const info = "beginFn()"
      let dsc = CoreDxTxRef(
        methods: db.txMethods(? aBase.txBegin info, ? kBase.txBegin info))
      ok(db.bless dsc),

    newCaptureFn: proc(flags: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] =
      ok(db.bless flags.tracerSetup()),

    persistentFn: proc(): CoreDbRc[void] =
      persistent())

# ------------------------------------------------------------------------------
# Public constructor and helper
# ------------------------------------------------------------------------------

proc create*(dbType: CoreDbType; kdb: KvtDbRef; adb: AristoDbRef): CoreDbRef =
  ## Constructor helper

  # Local extensions
  var db = AristoCoreDbRef()
  db.adbBase = AristoBaseRef.init(db, adb)
  db.kdbBase = KvtBaseRef.init(db, kdb)

  # Base descriptor
  db.dbType = dbType
  db.methods = db.baseMethods()
  db.bless()

proc newAristoMemoryCoreDbRef*(qlr: QidLayoutRef): CoreDbRef =
  AristoDbMemory.create(
    KvtDbRef.init(use_kvt.MemBackendRef),
    AristoDbRef.init(use_ari.MemBackendRef, qlr))

proc newAristoMemoryCoreDbRef*(): CoreDbRef =
  AristoDbMemory.create(
    KvtDbRef.init(use_kvt.MemBackendRef),
    AristoDbRef.init(use_ari.MemBackendRef))

proc newAristoVoidCoreDbRef*(): CoreDbRef =
  AristoDbVoid.create(
    KvtDbRef.init(use_kvt.VoidBackendRef),
    AristoDbRef.init(use_ari.VoidBackendRef))

# ------------------------------------------------------------------------------
# Public helpers, e.g. for direct backend access
# ------------------------------------------------------------------------------

func toAristoProfData*(
    db: CoreDbRef;
      ): tuple[aristo: AristoDbProfListRef, kvt: KvtDbProfListRef]  =
  when CoreDbEnableApiProfiling:
    if db.isAristo:
      result.aristo = db.AristoCoreDbRef.adbBase.api.AristoApiProfRef.data
      result.kvt = db.AristoCoreDbRef.kdbBase.api.KvtApiProfRef.data

func toAristoApi*(kvt: CoreDxKvtRef): KvtApiRef =
  if kvt.parent.isAristo:
    return AristoCoreDbRef(kvt.parent).kdbBase.api

func toAristoApi*(mpt: CoreDxMptRef): AristoApiRef =
  if mpt.parent.isAristo:
    return mpt.to(AristoApiRef)

func toAristo*(kBe: CoreDbKvtBackendRef): KvtDbRef =
  if not kBe.isNil and kBe.parent.isAristo:
    return kBe.AristoCoreDbKvtBE.kdb

func toAristo*(mBe: CoreDbMptBackendRef): AristoDbRef =
  if not mBe.isNil and mBe.parent.isAristo:
    return mBe.AristoCoreDbMptBE.adb

# ------------------------------------------------------------------------------
# Public aristo iterators
# ------------------------------------------------------------------------------

include
  ./aristo_db/aristo_replicate

# ------------------------

iterator aristoKvtPairsVoid*(dsc: CoreDxKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = dsc.toAristoApi()
    p = api.forkTop(dsc.to(KvtDbRef)).valueOrApiError "aristoKvtPairs()"
  defer: discard api.forget(p)
  for (k,v) in use_kvt.VoidBackendRef.walkPairs p:
    yield (k,v)

iterator aristoKvtPairsMem*(dsc: CoreDxKvtRef): (Blob,Blob) {.rlpRaise.} =
  let
    api = dsc.toAristoApi()
    p = api.forkTop(dsc.to(KvtDbRef)).valueOrApiError "aristoKvtPairs()"
  defer: discard api.forget(p)
  for (k,v) in use_kvt.MemBackendRef.walkPairs p:
    yield (k,v)

iterator aristoMptPairs*(dsc: CoreDxMptRef): (Blob,Blob) {.noRaise.} =
  let
    api = dsc.to(AristoApiRef)
    mpt = dsc.to(AristoDbRef)
  for (k,v) in mpt.rightPairs LeafTie(root: dsc.rootID):
    yield (api.pathAsBlob(k.path), api.serialise(mpt, v).valueOr(EmptyBlob))

iterator aristoReplicateMem*(dsc: CoreDxMptRef): (Blob,Blob) {.rlpRaise.} =
  ## Instantiation for `MemBackendRef`
  for k,v in aristoReplicate[use_ari.MemBackendRef](dsc):
    yield (k,v)

iterator aristoReplicateVoid*(dsc: CoreDxMptRef): (Blob,Blob) {.rlpRaise.} =
  ## Instantiation for `VoidBackendRef`
  for k,v in aristoReplicate[use_ari.VoidBackendRef](dsc):
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
