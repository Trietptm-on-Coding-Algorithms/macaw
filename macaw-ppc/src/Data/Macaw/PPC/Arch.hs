{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
module Data.Macaw.PPC.Arch (
  PPCTermStmt(..),
  rewriteTermStmt,
  PPCStmt(..),
  rewriteStmt,
  PPCPrimFn(..),
  rewritePrimFn,
  ppcPrimFnHasSideEffects,
  PPCArchConstraints,
  ppcInstructionMatcher
  ) where

import           GHC.TypeLits

import qualified Text.PrettyPrint.ANSI.Leijen as PP
import qualified Data.Parameterized.NatRepr as NR
import qualified Data.Parameterized.TraversableFC as FC
import qualified Data.Parameterized.TraversableF as TF
import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.CFG.Block as MC
import           Data.Macaw.CFG.Rewriter ( Rewriter, rewriteValue, evalRewrittenArchFn, appendRewrittenArchStmt )
import qualified Data.Macaw.Memory as MM
import qualified Data.Macaw.Types as MT

import qualified Dismantle.PPC as D
import qualified SemMC.Architecture.PPC32 as PPC32
import qualified SemMC.Architecture.PPC64 as PPC64
import qualified SemMC.Architecture.PPC.Eval as E

import qualified Data.Macaw.SemMC.Generator as G
import qualified Data.Macaw.SemMC.Operands as O
import           Data.Macaw.PPC.Operand ()
import           Data.Macaw.PPC.PPCReg

data PPCTermStmt ids where
  -- | A representation of the PowerPC @sc@ instruction
  --
  -- That instruction technically takes an argument, but it must be zero so we
  -- don't preserve it.
  PPCSyscall :: PPCTermStmt ids
  -- | A non-syscall trap initiated by the @td@, @tw@, @tdi@, or @twi@ instructions
  PPCTrap :: PPCTermStmt ids

deriving instance Show (PPCTermStmt ids)

type instance MC.ArchTermStmt PPC64.PPC = PPCTermStmt
type instance MC.ArchTermStmt PPC32.PPC = PPCTermStmt

instance MC.PrettyF PPCTermStmt where
  prettyF ts =
    case ts of
      PPCSyscall -> PP.text "ppc_syscall"
      PPCTrap -> PP.text "ppc_trap"

rewriteTermStmt :: PPCTermStmt src -> Rewriter ppc s src tgt (PPCTermStmt tgt)
rewriteTermStmt s =
  case s of
    PPCSyscall -> pure PPCSyscall
    PPCTrap -> pure PPCTrap

data PPCStmt ppc (v :: MT.Type -> *) where
  Attn :: PPCStmt ppc v
  Sync :: PPCStmt ppc v
  Isync :: PPCStmt ppc v
  -- These are cache hints
  Dcba   :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> PPCStmt ppc v
  Dcbf   :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> PPCStmt ppc v
  Dcbi   :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> PPCStmt ppc v
  Dcbst  :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> PPCStmt ppc v
  Dcbz   :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> PPCStmt ppc v
  Dcbzl  :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> PPCStmt ppc v
  Dcbt   :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> v (MT.BVType 5) -> PPCStmt ppc v
  Dcbtst :: v (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc))) -> v (MT.BVType 5) -> PPCStmt ppc v

instance TF.FunctorF (PPCStmt ppc) where
  fmapF = TF.fmapFDefault

instance TF.FoldableF (PPCStmt ppc) where
  foldMapF = TF.foldMapFDefault

instance TF.TraversableF (PPCStmt ppc) where
  traverseF go stmt =
    case stmt of
      Attn -> pure Attn
      Sync -> pure Sync
      Isync -> pure Isync
      Dcba ea -> Dcba <$> go ea
      Dcbf ea -> Dcbf <$> go ea
      Dcbi ea -> Dcbi <$> go ea
      Dcbst ea -> Dcbst <$> go ea
      Dcbz ea -> Dcbz <$> go ea
      Dcbzl ea -> Dcbzl <$> go ea
      Dcbt ea th -> Dcbt <$> go ea <*> go th
      Dcbtst ea th -> Dcbtst <$> go ea <*> go th

instance MC.IsArchStmt (PPCStmt ppc) where
  ppArchStmt pp stmt =
    case stmt of
      Attn -> PP.text "ppc_attn"
      Sync -> PP.text "ppc_sync"
      Isync -> PP.text "ppc_isync"
      Dcba ea -> PP.text "ppc_dcba" PP.<+> pp ea
      Dcbf ea -> PP.text "ppc_dcbf" PP.<+> pp ea
      Dcbi ea -> PP.text "ppc_dcbi" PP.<+> pp ea
      Dcbst ea -> PP.text "ppc_dcbst" PP.<+> pp ea
      Dcbz ea -> PP.text "ppc_dcbz" PP.<+> pp ea
      Dcbzl ea -> PP.text "ppc_dcbzl" PP.<+> pp ea
      Dcbt ea th -> PP.text "ppc_dcbt" PP.<+> pp ea PP.<+> pp th
      Dcbtst ea th -> PP.text "ppc_dcbtst" PP.<+> pp ea PP.<+> pp th

type instance MC.ArchStmt PPC64.PPC = PPCStmt PPC64.PPC
type instance MC.ArchStmt PPC32.PPC = PPCStmt PPC32.PPC

rewriteStmt :: (MC.ArchStmt ppc ~ PPCStmt ppc) => PPCStmt ppc (MC.Value ppc src) -> Rewriter ppc s src tgt ()
rewriteStmt s = do
  s' <- TF.traverseF rewriteValue s
  appendRewrittenArchStmt s'

data PPCPrimFn ppc f tp where
  -- | Unsigned division
  --
  -- Division by zero does not have side effects, but instead produces an undefined value
  UDiv :: NR.NatRepr (MC.RegAddrWidth (MC.ArchReg ppc))
       -> f (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))
       -> f (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))
       -> PPCPrimFn ppc f (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))
  -- | Signed division
  --
  -- Division by zero does not have side effects, but instead produces an undefined value
  SDiv :: NR.NatRepr (MC.RegAddrWidth (MC.ArchReg ppc))
       -> f (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))
       -> f (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))
       -> PPCPrimFn ppc f (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))

  FPIsQNaN :: !(MT.FloatInfoRepr flt) -> !(f (MT.FloatType flt)) -> PPCPrimFn ppc f MT.BoolType
  FPIsSNaN :: !(MT.FloatInfoRepr flt) -> !(f (MT.FloatType flt)) -> PPCPrimFn ppc f MT.BoolType
  FPCvt :: !(MT.FloatInfoRepr flt) -> !(f (MT.FloatType flt)) -> !(MT.FloatInfoRepr flt') -> PPCPrimFn ppc f (MT.FloatType flt')

  -- | Uninterpreted floating point functions
  FP1 :: !String -- ^ the name of the function
      -> !(f (MT.BVType 128)) -- ^ arg 1
      -> !(f (MT.BVType 32)) -- ^ current fpscr
      -> PPCPrimFn ppc f (MT.BVType 160)
  FP2 :: !String
      -> !(f (MT.BVType 128))
      -> !(f (MT.BVType 128))
      -> !(f (MT.BVType 32))
      -> PPCPrimFn ppc f (MT.BVType 160)
  FP3 :: !String
      -> !(f (MT.BVType 128))
      -> !(f (MT.BVType 128))
      -> !(f (MT.BVType 128))
      -> !(f (MT.BVType 32))
      -> PPCPrimFn ppc f (MT.BVType 160)

  -- | Uninterpreted vector functions
  Vec1 :: !String -- ^ the name of the function
       -> !(f (MT.BVType 128))
       -> !(f (MT.BVType 32))
       -> PPCPrimFn ppc f (MT.BVType 160)
  Vec2 :: String -- ^ the name of the function
       -> !(f (MT.BVType 128))
       -> !(f (MT.BVType 128))
       -> !(f (MT.BVType 32))
       -> PPCPrimFn ppc f (MT.BVType 160)
  Vec3 :: String -- ^ the name of the function
       -> !(f (MT.BVType 128))
       -> !(f (MT.BVType 128))
       -> !(f (MT.BVType 128))
       -> !(f (MT.BVType 32))
       -> PPCPrimFn ppc f (MT.BVType 160)

instance (1 <= MC.RegAddrWidth (MC.ArchReg ppc)) => MT.HasRepr (PPCPrimFn ppc (MC.Value ppc ids)) MT.TypeRepr where
  typeRepr f =
    case f of
      UDiv rep _ _ -> MT.BVTypeRepr rep
      SDiv rep _ _ -> MT.BVTypeRepr rep

      FPIsQNaN _ _ -> MT.BoolTypeRepr
      FPIsSNaN _ _ -> MT.BoolTypeRepr
      FPCvt _ _ rep -> MT.floatTypeRepr rep

      FP1 _    _ _      -> MT.BVTypeRepr MT.knownNat
      FP2 _    _ _ _    -> MT.BVTypeRepr MT.knownNat
      FP3 _    _ _ _ _  -> MT.BVTypeRepr MT.knownNat

      Vec1 _   _ _      -> MT.BVTypeRepr MT.knownNat
      Vec2 _   _ _ _    -> MT.BVTypeRepr MT.knownNat
      Vec3 _   _ _ _ _  -> MT.BVTypeRepr MT.knownNat


-- | Right now, none of the primitive functions has a side effect.  That will
-- probably change.
ppcPrimFnHasSideEffects :: PPCPrimFn ppc f tp -> Bool
ppcPrimFnHasSideEffects pf =
  case pf of
    UDiv {} -> False
    SDiv {} -> False
    FPIsQNaN {} -> False
    FPIsSNaN {} -> False
    FPCvt {} -> False
    FP1 {} -> False
    FP2 {} -> False
    FP3 {} -> False
    Vec1 {} -> False
    Vec2 {} -> False
    Vec3 {} -> False

rewritePrimFn :: (PPCArchConstraints ppc, MC.ArchFn ppc ~ PPCPrimFn ppc)
              => PPCPrimFn ppc (MC.Value ppc src) tp
              -> Rewriter ppc s src tgt (MC.Value ppc tgt tp)
rewritePrimFn f =
  case f of
    UDiv rep lhs rhs -> do
      tgtFn <- UDiv rep <$> rewriteValue lhs <*> rewriteValue rhs
      evalRewrittenArchFn tgtFn
    SDiv rep lhs rhs -> do
      tgtFn <- SDiv rep <$> rewriteValue lhs <*> rewriteValue rhs
      evalRewrittenArchFn tgtFn
    FPIsQNaN info v -> do
      tgt <- FPIsQNaN info <$> rewriteValue v
      evalRewrittenArchFn tgt
    FPIsSNaN info v -> do
      tgt <- FPIsSNaN info <$> rewriteValue v
      evalRewrittenArchFn tgt
    FPCvt rep1 v rep2 -> do
      tgt <- FPCvt rep1 <$> rewriteValue v <*> pure rep2
      evalRewrittenArchFn tgt
    FP1 name op fpscr -> do
      tgtFn <- FP1 name <$> rewriteValue op <*> rewriteValue fpscr
      evalRewrittenArchFn tgtFn
    FP2 name op1 op2 fpscr -> do
      tgtFn <- FP2 name <$> rewriteValue op1 <*> rewriteValue op2 <*> rewriteValue fpscr
      evalRewrittenArchFn tgtFn
    FP3 name op1 op2 op3 fpscr -> do
      tgtFn <- FP3 name <$> rewriteValue op1 <*> rewriteValue op2 <*> rewriteValue op3 <*> rewriteValue fpscr
      evalRewrittenArchFn tgtFn
    Vec1 name op vscr -> do
      tgtFn <- Vec1 name <$> rewriteValue op <*> rewriteValue vscr
      evalRewrittenArchFn tgtFn
    Vec2 name op1 op2 vscr -> do
      tgtFn <- Vec2 name <$> rewriteValue op1 <*> rewriteValue op2 <*> rewriteValue vscr
      evalRewrittenArchFn tgtFn
    Vec3 name op1 op2 op3 vscr -> do
      tgtFn <- Vec3 name <$> rewriteValue op1 <*> rewriteValue op2 <*> rewriteValue op3 <*> rewriteValue vscr
      evalRewrittenArchFn tgtFn

ppPrimFn :: (Applicative m) => (forall u . f u -> m PP.Doc) -> PPCPrimFn ppc f tp -> m PP.Doc
ppPrimFn pp f =
  case f of
    UDiv _ lhs rhs -> ppBinary "ppc_udiv" <$> pp lhs <*> pp rhs
    SDiv _ lhs rhs -> ppBinary "ppc_sdiv" <$> pp lhs <*> pp rhs
    FPIsQNaN _info v -> ppUnary "ppc_fp_isqnan" <$> pp v
    FPIsSNaN _info v -> ppUnary "ppc_fp_issnan" <$> pp v
    FPCvt _rep1 v _rep2 -> ppUnary "ppc_fp_cvt" <$> pp v
    FP1 n r1 fpscr -> ppBinary ("ppc_fp1 " ++ n) <$> pp r1 <*> pp fpscr
    FP2 n r1 r2 fpscr -> pp3 ("ppc_fp2 " ++ n) <$> pp r1 <*> pp r2 <*> pp fpscr
    FP3 n r1 r2 r3 fpscr -> pp4 ("ppc_fp3 " ++ n) <$> pp r1 <*> pp r2 <*> pp r3 <*> pp fpscr
    Vec1 n r1 vscr -> ppBinary ("ppc_vec1 " ++ n) <$> pp r1 <*> pp vscr
    Vec2 n r1 r2 vscr -> pp3 ("ppc_vec2" ++ n) <$> pp r1 <*> pp r2 <*> pp vscr
    Vec3 n r1 r2 r3 vscr -> pp4 ("ppc_vec3" ++ n) <$> pp r1 <*> pp r2 <*> pp r3 <*> pp vscr
  where
    ppUnary s v' = PP.text s PP.<+> v'
    ppBinary s v1' v2' = PP.text s PP.<+> v1' PP.<+> v2'
    pp3 s v1' v2' v3' = PP.text s PP.<+> v1' PP.<+> v2' PP.<+> v3'
    pp4 s v1' v2' v3' v4' = PP.text s PP.<+> v1' PP.<+> v2' PP.<+> v3' PP.<+> v4'

instance MC.IsArchFn (PPCPrimFn ppc) where
  ppArchFn = ppPrimFn

instance FC.FunctorFC (PPCPrimFn ppc) where
  fmapFC = FC.fmapFCDefault

instance FC.FoldableFC (PPCPrimFn ppc) where
  foldMapFC = FC.foldMapFCDefault

instance FC.TraversableFC (PPCPrimFn ppc) where
  traverseFC go f =
    case f of
      UDiv rep lhs rhs -> UDiv rep <$> go lhs <*> go rhs
      SDiv rep lhs rhs -> SDiv rep <$> go lhs <*> go rhs
      FPIsQNaN info v -> FPIsQNaN info <$> go v
      FPIsSNaN info v -> FPIsSNaN info <$> go v
      FPCvt rep1 v rep2 -> FPCvt rep1 <$> go v <*> pure rep2
      FP1 name op fpscr -> FP1 name <$> go op <*> go fpscr
      FP2 name op1 op2 fpscr -> FP2 name <$> go op1 <*> go op2 <*> go fpscr
      FP3 name op1 op2 op3 fpscr -> FP3 name <$> go op1 <*> go op2 <*> go op3 <*> go fpscr
      Vec1 name op vscr -> Vec1 name <$> go op <*> go vscr
      Vec2 name op1 op2 vscr -> Vec2 name <$> go op1 <*> go op2 <*> go vscr
      Vec3 name op1 op2 op3 vscr -> Vec3 name <$> go op1 <*> go op2 <*> go op3 <*> go vscr

type instance MC.ArchFn PPC64.PPC = PPCPrimFn PPC64.PPC
type instance MC.ArchFn PPC32.PPC = PPCPrimFn PPC32.PPC

type PPCArchConstraints ppc = ( MC.ArchReg ppc ~ PPCReg ppc
                              , MC.ArchFn ppc ~ PPCPrimFn ppc
                              , MC.ArchStmt ppc ~ PPCStmt ppc
                              , MC.ArchTermStmt ppc ~ PPCTermStmt
                              , ArchWidth ppc
                              , MM.MemWidth (MC.RegAddrWidth (MC.ArchReg ppc))
                              , 1 <= MC.RegAddrWidth (PPCReg ppc)
                              , KnownNat (MC.RegAddrWidth (PPCReg ppc))
                              , MC.ArchConstraints ppc
                              , O.ExtractValue ppc D.GPR (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))
                              , O.ExtractValue ppc (Maybe D.GPR) (MT.BVType (MC.RegAddrWidth (MC.ArchReg ppc)))
                              )

memrrToEffectiveAddress :: forall ppc ids s n
                         . (n ~ MC.RegAddrWidth (MC.ArchReg ppc), PPCArchConstraints ppc)
                        => D.MemRR
                        -> G.Generator ppc ids s (MC.Value ppc ids (MT.BVType n))
memrrToEffectiveAddress memrr = do
  offset <- O.extractValue (E.interpMemrrOffsetExtractor memrr)
  base <- O.extractValue (E.interpMemrrBaseExtractor memrr)
  isr0 <- O.extractValue (E.interpIsR0 (E.interpMemrrBaseExtractor memrr))
  let repr = MT.knownNat @n
  let zero = MC.BVValue repr 0
  b <- G.addExpr (G.AppExpr (MC.Mux (MT.BVTypeRepr repr) isr0 zero base))
  G.addExpr (G.AppExpr (MC.BVAdd repr b offset))

-- | Manually-provided semantics for instructions whose full semantics cannot be
-- expressed in our semantics format.
--
-- This includes instructions with special side effects that we don't have a way
-- to talk about in the semantics; especially useful for architecture-specific
-- terminator statements.
ppcInstructionMatcher :: (PPCArchConstraints ppc) => D.Instruction -> Maybe (G.Generator ppc ids s ())
ppcInstructionMatcher (D.Instruction opc operands) =
  case opc of
    D.SC -> Just (G.finishWithTerminator (MC.ArchTermStmt PPCSyscall))
    D.TRAP -> Just (G.finishWithTerminator (MC.ArchTermStmt PPCTrap))
    D.ATTN -> Just (G.addStmt (MC.ExecArchStmt Attn))
    D.SYNC -> Just (G.addStmt (MC.ExecArchStmt Sync))
    D.ISYNC -> Just (G.addStmt (MC.ExecArchStmt Isync))
    D.DCBA ->
      case operands of
        D.Memrr memrr D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          G.addStmt (MC.ExecArchStmt (Dcba ea))
    D.DCBF ->
      case operands of
        D.Memrr memrr D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          G.addStmt (MC.ExecArchStmt (Dcbf ea))
    D.DCBI ->
      case operands of
        D.Memrr memrr D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          G.addStmt (MC.ExecArchStmt (Dcbi ea))
    D.DCBST ->
      case operands of
        D.Memrr memrr D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          G.addStmt (MC.ExecArchStmt (Dcbst ea))
    D.DCBZ ->
      case operands of
        D.Memrr memrr D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          G.addStmt (MC.ExecArchStmt (Dcbz ea))
    D.DCBZL ->
      case operands of
        D.Memrr memrr D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          G.addStmt (MC.ExecArchStmt (Dcbzl ea))
    D.DCBT ->
      case operands of
        D.Memrr memrr D.:< D.U5imm imm D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          th <- O.extractValue imm
          G.addStmt (MC.ExecArchStmt (Dcbt ea th))
    D.DCBTST ->
      case operands of
        D.Memrr memrr D.:< D.U5imm imm D.:< D.Nil -> Just $ do
          ea <- memrrToEffectiveAddress memrr
          th <- O.extractValue imm
          G.addStmt (MC.ExecArchStmt (Dcbtst ea th))
    _ -> Nothing
