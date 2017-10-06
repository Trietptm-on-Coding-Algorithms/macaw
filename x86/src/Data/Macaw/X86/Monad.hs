{-|
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This defines the typeclasses that must be implemented to obtain
semantics from x86 instructions.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
module Data.Macaw.X86.Monad
  ( -- * Type
    XMMType
  , RepValSize(..)
  , repValHasSupportedWidth
  , repValSizeMemRepr
  , repValSizeByteCount
  , Data.Macaw.Types.FloatInfoRepr(..)
  , Data.Macaw.Types.floatInfoBits
  , floatMemRepr
    -- * RegisterView
  , RegisterView
  , RegisterViewType(..)
  , registerViewRead
  , registerViewWrite
  , registerViewBase
  , registerViewSize
  , registerViewReg
  , registerViewType
    -- * Location
  , Location(..)
  , ppLocation
  , x87reg_mmx
  , fullRegister
  , subRegister
  , reg_low8
  , reg_high8
  , reg_low16
  , reg_low32

  , cf_loc
  , pf_loc
  , af_loc
  , zf_loc
  , sf_loc
  , tf_loc
  , if_loc
  , df_loc
  , of_loc
    -- X87
  , c0_loc
  , c1_loc
  , c2_loc
  , c3_loc

  , mkFPAddr
  , packWord
  , unpackWord
  -- ** Registers
  , rip
  , rax, rbx, rcx, rdx, rsp, rbp, rsi, rdi
  , eax, ebx, ecx, edx
  , ax, bx, cx, dx
  , al, dl
  , ah
    -- * Value operations
  , IsValue(..)
  , bvKLit
  , (.+)
  , (.-)
  , (.*)
  , (.&&.)
  , (.||.)
  , Pred
    -- * Semantics
  , SIMDWidth(..)
  , Semantics(..)
  , Value
  , BVValue
  , MLocation
  , SupportedBVWidth
  , IsLocationBV
  , ExceptionClass(..)
  , Primitive(..)
    -- * Re-exports
  , type (TypeLits.<=)
  , type Flexdis86.Sizes.SizeConstraint(..)
  , module Flexdis86.Segment
  ) where

import qualified Data.Bits as Bits
import           Data.Char (toLower)
import           Data.Macaw.CFG (MemRepr(..), memReprBytes)
import           Data.Macaw.Memory (Endianness(..))
import           Data.Macaw.Types
import           Data.Parameterized.Classes
import           Data.Parameterized.NatRepr
import           GHC.TypeLits as TypeLits
import           Text.PrettyPrint.ANSI.Leijen as PP hiding ((<$>))

import qualified Flexdis86 as F
import           Flexdis86.Segment
  ( Segment
  , pattern ES
  , pattern CS
  , pattern SS
  , pattern DS
  , pattern FS
  , pattern GS
  )
import           Flexdis86.Sizes (SizeConstraint(..))

import           Data.Macaw.X86.X86Reg (X86Reg(..))
import qualified Data.Macaw.X86.X86Reg as R
import           Data.Macaw.X86.X87ControlReg

type XMMType    = BVType 128

------------------------------------------------------------------------
-- Sub registers
--
-- See comments above 'registerViewRead'.

-- | The different kinds of register views.
--
-- We introduce this "tag" type, vs embedding the read and write
-- functions directly in the 'RegisterView', in order to reify the
-- read and write functions: these tags can be inspected at run time,
-- but the corresponding read and write functions cannot. The
-- 'registerViewRead' and 'registerViewWrite' functions below map a
-- 'RegisterView' to it's corresponding read and write functions,
-- using the constraints embedded in the 'RegisterViewType' tag.
--
-- We could optimize the common case of full registers by introducing
-- a @IdentityView@ of type @RegisterViewType cl 0
-- (R.registerclassbits cl)@ whose read view is @\x -> x@ and write
-- view is @\x y -> y@.
data RegisterViewType m (b :: Nat) (n :: Nat)
  = ( 1 <= n
    , n <= m
    )
    => DefaultView
  | ( 1 <= n
    , 1 <= m
    , n <= m
    , 1 <= m - n
    , m - n <= m
    , ((m - n) + n) ~ m
    , b ~ 0
    )
    => OneExtendOnWrite
  | ( 1 <= n
    , 1 <= m
    , n <= m
    , 1 <= m - n
    , m - n <= m
    , ((m - n) + n) ~ m
    , b ~ 0
    )
    => ZeroExtendOnWrite

-- | A view into a register / a subregister.
data RegisterView w b n
  = (1 <= n, b + n <= w)
 => RegisterView
    { _registerViewBase :: NatRepr b
    , _registerViewSize :: NatRepr n
    , _registerViewReg :: X86Reg (BVType w)
    , _registerViewType :: RegisterViewType w b n
    }


-- * Destructors for 'RegisterView's.

registerViewBase :: RegisterView w b n -> NatRepr b
registerViewBase = _registerViewBase

registerViewSize :: RegisterView w b n -> NatRepr n
registerViewSize = _registerViewSize

registerViewReg :: RegisterView w b n -> X86Reg (BVType w)
registerViewReg = _registerViewReg

registerViewType :: RegisterView w b n -> RegisterViewType w b n
registerViewType = _registerViewType

-- * Read and write views for 'RegisterView's.

-- | Extract 'n' bits starting at base 'b'.
--
-- Assumes a big-endian 'IsValue' semantics.
defaultRegisterViewRead
  :: forall v b n m
  .  ( 1 <= n
     , n <= m
     , IsValue v
     )
  => NatRepr b
  -> NatRepr n
  -> X86Reg (BVType m)
  -> v (BVType m)
  -> v (BVType n)
defaultRegisterViewRead b n _rn v0
  | LeqProof <- leqTrans (LeqProof :: LeqProof 1 n) (LeqProof :: LeqProof n m) =
    bvTrunc n $ v0 `bvShr` bvLit (bv_width v0) (natValue b)

-- | Read a register via a view.
--
-- The read and write operations specify how to read and write a
-- subregister value based on the current value @v0@ in the full
-- register. The write operation also depends on the new subregister
-- value @v@ to be written.
--
-- See 'defaultRegisterViewRead' and 'defaultRegisterViewWrite'
-- implement the common case (e.g. for @ax@ as a subregister of
-- @rax@).
--
-- The special cases motivating introduction of the 'RegisterView'
-- data type are:
--
-- * 32-bit subregisters of 64-bit general purpose registers
--   (e.g. @eax@ as a subregister of @rax@), where the high-order 32
--   bits should be zeroed out on writes
--
-- * 64-bit mmx subregisters of x87 registers, where the high-order 16
--   bits should be oned out on writes.
--
-- Note that some instructions, such as @movss@ and @movsd@, specify
-- what appears to be special treatment of subregisters as part of
-- their semantics. We don't expect these *explicit* instruction
-- semantics to be implemented using 'RegisterView'. Rather,
-- 'RegisterView' is intended to implement the *implicit* special
-- treatment of some aliased registers, namely the two cases mentioned
-- above. (But this distinction is arbitrary, and we could simplify
-- some semantic implementations by treating the lower-half of an XMM
-- register as a named subregister, using a 'RegisterView').
--
-- Note: there is no type-level relationship between the base @b@ and
-- size @n@ params and the read/write views, but the base and size are
-- expected to specify which bits are read by read view.
--
-- MAYBE TODO: the read and write views have an @IsValue v@
-- constraint, but the implementations only rely on a small subset of
-- the 'IsValue' operations. So, it might make sense to factor these
-- operations out into a separate class. The operations we need for
-- reads and writes are subset of the the basic bitvector operations;
-- we need:
--
-- - 'bvLit': create a literal representing a number
-- - 'bvShl', 'bvShr': logical shifts
-- - 'bvTrunc': truncation
-- - 'bv_width': number of bits in the vector
-- - 'bvComplement': complement the bits
-- - 'uext'': zero extension
-- - '(.|.)': bit-wise OR
--
-- If we factored this out into a separate class, it would probably
-- make sense to include a few more "basic bitvector operations" in
-- the new class:
--
-- - bit-wise AND
-- - arithmetic shift
-- - signed extension
--
-- Note that we don't need arithmetic on bit vectors, neither as ints
-- nor as floats.
registerViewRead
  :: IsValue v
  => RegisterView m b n
  -> v (BVType m)
  -> v (BVType n)
registerViewRead v =
  case registerViewType v of
    DefaultView -> defaultRegisterViewRead b n rn
    OneExtendOnWrite -> defaultRegisterViewRead b n rn
    ZeroExtendOnWrite -> defaultRegisterViewRead b n rn
  where
    b  = _registerViewBase v
    n  = _registerViewSize v
    rn = _registerViewReg v

-- | Update the 'n' bits starting at base 'b', leaving other bits
-- unchanged.
--
-- Assumes a big-endian 'IsValue' semantics.
defaultRegisterViewWrite
  :: forall b m n v
  . ( 1 <= n
    , n <= m
    , IsValue v
    )
  => NatRepr b
  -> NatRepr n
  -> X86Reg (BVType m)
  -> v (BVType m)
     -- ^ Value being modified
  -> v (BVType n)
     -- ^ Value to write
  -> v (BVType m)
defaultRegisterViewWrite b n rn v0 write_val
  | LeqProof <- leqTrans (LeqProof :: LeqProof 1 n) (LeqProof :: LeqProof n m) =
  -- Truncation 'bvTrunc' requires that the result vector has non-zero
  -- length, so we build the concatenation
  --
  --   h ++ m ++ l
  --
  -- using bitwise OR:
  --
  --   (h ++ 0^|m ++ l|)     ||
  --   (0^|h| ++ m ++ 0^|l|) ||
  --   (0^|h ++ m| ++ l)
  -- highOrderBits  .|. lowOrderBits
  let -- Generate the mask for the new bits
      myMask = maxUnsigned n `Bits.shiftL` fromInteger (natValue b)
      -- Generate max for old bits.
      notMyMask = Bits.complement myMask
      prevBits = v0 .&. bvLit w notMyMask
      w = bv_width v0
      cl = typeWidth rn
      b' = natValue b
      middleOrderBits = uext cl write_val `bvShl` bvLit cl b'
   in prevBits .|. middleOrderBits


-- | Write a register via a view.
registerViewWrite
  :: ( IsValue v
     )
  => RegisterView w b x1
  -> v (BVType w)
  -> v (BVType x1)
  -> v (BVType w)
registerViewWrite rv =
  case _registerViewType rv of
    DefaultView
      -- Just write the full register if possible
      | Just Refl <- b `testEquality` n0
      , Just Refl <- n `testEquality` typeWidth rn
      , DefaultView <- _registerViewType rv -> \ _v0 v -> v
      -- Otherwise use the defaultRegisterViewWrite
      | otherwise -> defaultRegisterViewWrite b n rn
    OneExtendOnWrite ->
      let ones = bvComplement (bvLit (cl `subNat` n) 0)
       in constUpperBitsRegisterViewWrite n ones rn
    ZeroExtendOnWrite ->
      let zeros = bvLit (cl `subNat` n) 0
       in constUpperBitsRegisterViewWrite n zeros rn
  where
    b = _registerViewBase rv
    n = _registerViewSize rv
    rn = _registerViewReg rv
    cl = typeWidth rn

constUpperBitsRegisterViewWrite
  :: (IsValue v, 1 <= b, 1 <= e, (b + e) ~ f)
  => NatRepr a
  -> v (BVType b)
  -- ^ Constant bits.
  -> X86Reg (BVType c)
  -> v (BVType d)
  -> v (BVType e)
  -> v (BVType f)
constUpperBitsRegisterViewWrite _n c _rn _v0 v = bvCat c v

-- | The view for subregisters which are a slice of a full register.
sliceRegisterView
  :: ( 1     <= n
     , 1     <= m
     , n     <= m
     , b + n <= m
     )
  => NatRepr b
  -> NatRepr n
  -> X86Reg (BVType m)
  -> RegisterView m b n
sliceRegisterView b n rn =
  RegisterView
    { _registerViewBase = b
    , _registerViewSize = n
    , _registerViewReg = rn
    , _registerViewType = DefaultView
    }

-- | The view for 32-bit general purpose and mmx registers.
--
-- These are the special / weird sub registers where the upper bits of
-- the underlying full register are implicitly set to a constant on
-- writes.
constUpperBitsOnWriteRegisterView
  :: ( 1 <= n
     , n <= w
     )
  => NatRepr n
  -> RegisterViewType w 0 n
  -> X86Reg (BVType w)
  -> RegisterView w 0 n
constUpperBitsOnWriteRegisterView n rt rn  =
  RegisterView
    { _registerViewBase = n0
    , _registerViewSize = n
    , _registerViewReg = rn
    , _registerViewType = rt
    }

------------------------------------------------------------------------
-- Location

-- | This returns the type associated with values that can be read
-- or assigned for the semantics monad.
data Location addr (tp :: Type) where
  -- A location in the virtual address space of the process.
  MemoryAddr :: !addr -> !(MemRepr tp) -> Location addr tp

  FullRegister :: !(X86Reg tp)
               -> Location addr tp

  Register :: !(RegisterView m b n)
           -> Location addr (BVType n)

  ControlReg :: !F.ControlReg
             -> Location addr (BVType 64)

  DebugReg :: !F.DebugReg
           -> Location addr (BVType 64)

  SegmentReg :: !Segment
             -> Location addr (BVType 16)

  X87ControlReg :: !(X87_ControlReg w)
                -> Location addr (BVType w)

  -- The register stack: the argument is an offset from the stack
  -- top, so X87Register 0 is the top, X87Register 1 is the second,
  -- and so forth.
  X87StackRegister :: !Int
                   -> Location addr (FloatType X86_80Float)

-- Equality and ordering.

compareRegisterViewType :: RegisterViewType w b n -> RegisterViewType w' b' n' -> Ordering
DefaultView `compareRegisterViewType` DefaultView = EQ
DefaultView `compareRegisterViewType` _ = LT
_ `compareRegisterViewType` DefaultView = GT
OneExtendOnWrite `compareRegisterViewType` OneExtendOnWrite = EQ
OneExtendOnWrite `compareRegisterViewType` _ = LT
_ `compareRegisterViewType` OneExtendOnWrite = GT
ZeroExtendOnWrite `compareRegisterViewType` ZeroExtendOnWrite = EQ

compareRegisterView :: RegisterView w b n -> RegisterView w' b' n' -> Ordering
compareRegisterView rv rv' =
  case ( _registerViewBase rv `compareF` _registerViewBase rv'
       , _registerViewSize rv `compareF` _registerViewSize rv'
       , _registerViewReg rv `compareF` _registerViewReg rv'
       ) of
    (LTF, _, _) -> LT
    (GTF, _, _) -> GT
    (EQF, LTF, _) -> LT
    (EQF, GTF, _) -> GT
    (EQF, EQF, LTF) -> LT
    (EQF, EQF, GTF) -> GT
    (EQF, EQF, EQF) ->
      _registerViewType rv `compareRegisterViewType` _registerViewType rv'

instance Eq addr => EqF (Location addr) where
  MemoryAddr addr tp `eqF` MemoryAddr addr' tp'
    | Just Refl <- testEquality tp tp' = addr == addr'
  Register rv `eqF` Register rv'
    | EQ <- rv `compareRegisterView` rv' = True
  X87StackRegister i `eqF` X87StackRegister i' = i == i'
  _ `eqF` _ = False

instance Eq addr => Eq (Location addr tp) where
  (==) = eqF

instance Ord (RegisterViewType w b n) where
  compare = compareRegisterViewType

instance Ord (RegisterView w b n) where
  compare = compareRegisterView

instance Eq (RegisterViewType w b n) where
  rvt == rvt'
    | EQ <- rvt `compareRegisterViewType` rvt' = True
    | otherwise = False

instance Eq (RegisterView w b n) where
  rv == rv'
    | EQ <- rv `compareRegisterView` rv' = True
    | otherwise = False

-- | Pretty print 'S.Location'.
--
-- Note: this pretty printer ignores the embedded view functions in
-- 'RegisterView's, so the pretty printed value only indicates which
-- bits are in the view, not how the view is actually defined
--
-- Going back to pretty names for subregisters is pretty ad hoc;
-- see table at http://stackoverflow.com/a/1753627/470844. E.g.,
-- instead of @%ah@, we produce @%rax[8:16]@.
ppLocation :: forall addr tp. (addr -> Doc) -> Location addr tp -> Doc
ppLocation ppAddr loc = case loc of
  MemoryAddr addr _tr -> ppAddr addr
  Register rv -> ppReg rv
  FullRegister r -> text $ "%" ++ show r
  ControlReg r -> text (show r)
  DebugReg r -> text (show r)
  SegmentReg r -> text (show r)
  X87ControlReg r -> text ("x87_" ++ show r)
  X87StackRegister i -> text $ "x87_stack@" ++ show i
  where
    -- | Print subrange as Python-style slice @<location>[<low>:<high>]@.
    --
    -- The low bit is inclusive and the high bit is exclusive, but I
    -- can't bring myself to generate @<reg>[<low>:<high>)@ :)
    ppReg :: RegisterView w n cl -> Doc
    ppReg rv =
      text $ "%" ++ show (_registerViewReg rv) ++
        if b == 0 && s == (fromIntegral $ natValue (typeWidth $ _registerViewReg rv))
        then ""
        else "[" ++ show b ++ ":" ++ show s ++ "]"
      where
        b = natValue $ _registerViewBase rv
        s = natValue $ _registerViewSize rv

------------------------------------------------------------------------
-- Register-location smart constructors.

-- | Full register location.
fullRegister :: X86Reg tp
             -> Location addr tp
fullRegister = FullRegister

-- | Subregister location for simple subregisters.
--
-- I.e., a subregister which reads and writes @n@ bits at offset @b@,
-- and preserves remaining bits on writes.
subRegister
  :: ( 1 <= n
     , 1 <= m
     , n <= m
     , b + n <= m
     )
  => NatRepr b
  -> NatRepr n
  -> X86Reg (BVType m)
  -> Location addr (BVType n)
subRegister b n = Register . sliceRegisterView b n

-- | The view for 32-bit general purpose and mmx registers.
--
-- These are the special / weird sub registers where the upper bits of
-- the underlying full register are implicitly set to a constant on
-- writes.
constUpperBitsOnWriteRegister ::
  ( 1 <= n
  , n <= m
  )
  => NatRepr n
  -> RegisterViewType m 0 n
  -> X86Reg (BVType m)
  -> Location addr (BVType n)
constUpperBitsOnWriteRegister n rt =
  Register . constUpperBitsOnWriteRegisterView n rt

------------------------------------------------------------------------
-- Operations on locations.

instance HasRepr (Location addr) TypeRepr where
  typeRepr (MemoryAddr _ tp) = typeRepr tp
  typeRepr (FullRegister r)  = typeRepr r
  typeRepr (Register rv@RegisterView{}) = BVTypeRepr $ _registerViewSize rv
  typeRepr (ControlReg _)    = knownType
  typeRepr (DebugReg _)    = knownType
  typeRepr (SegmentReg _)    = knownType
  typeRepr (X87ControlReg r) =
    case x87ControlRegWidthIsPos r of
      LeqProof -> BVTypeRepr (typeRepr r)
  typeRepr (X87StackRegister _) = knownType

------------------------------------------------------------------------
-- Specific locations.

-- | CF flag
cf_loc :: Location addr BoolType
cf_loc = fullRegister R.CF

-- | PF flag
pf_loc :: Location addr BoolType
pf_loc = fullRegister R.PF

-- | AF flag
af_loc :: Location addr BoolType
af_loc = fullRegister R.AF

-- | ZF flag
zf_loc :: Location addr BoolType
zf_loc = fullRegister R.ZF

-- | SF flag
sf_loc :: Location addr BoolType
sf_loc = fullRegister R.SF

-- | TF flag
tf_loc :: Location addr BoolType
tf_loc = fullRegister R.TF

-- | IF flag
if_loc :: Location addr BoolType
if_loc = fullRegister R.IF

-- | DF flag
df_loc :: Location addr BoolType
df_loc = fullRegister R.DF

-- | OF flag
of_loc :: Location addr BoolType
of_loc = fullRegister R.OF

-- | x87 flags
c0_loc, c1_loc, c2_loc, c3_loc :: Location addr BoolType
c0_loc = fullRegister R.X87_C0
c1_loc = fullRegister R.X87_C1
c2_loc = fullRegister R.X87_C2
c3_loc = fullRegister R.X87_C3

-- | Maps float info repr to associated MemRepr.
floatMemRepr :: FloatInfoRepr flt -> MemRepr (FloatType flt)
floatMemRepr fir =
  case floatInfoBytesIsPos fir of
    LeqProof -> BVMemRepr (floatInfoBytes fir) LittleEndian

-- | Tuen an address into a location of size @n
mkFPAddr :: FloatInfoRepr flt -> addr -> Location addr (FloatType flt)
mkFPAddr fir addr = MemoryAddr addr (floatMemRepr fir)

-- | Return MMX register corresponding to x87 register.
--
-- An MMX register is the low 64-bits of an x87 register. These
-- registers have special semantics, defined in Volume 1 of the Intel
-- x86 manual: on write,the upper 16 bits of the underlying x87
-- register are oned out!
x87reg_mmx :: X86Reg R.X87_FPU -> Location addr (BVType 64)
x87reg_mmx r = constUpperBitsOnWriteRegister n64 OneExtendOnWrite r

-- | Return low 32-bits of register e.g. rax -> eax
--
-- These subregisters have special semantics, defined in Volume 1 of
-- the Intel x86 manual: on write, the upper 32 bits are zeroed out!
reg_low32 :: X86Reg R.GP -> Location addr (BVType 32)
reg_low32 r = constUpperBitsOnWriteRegister n32 ZeroExtendOnWrite r

-- | Return low 16-bits of register e.g. rax -> ax
reg_low16 :: X86Reg R.GP -> Location addr (BVType 16)
reg_low16 r = subRegister n0 n16 r

-- | Return low 8-bits of register e.g. rax -> al
reg_low8 :: X86Reg R.GP -> Location addr (BVType 8)
reg_low8 r = subRegister n0 n8 r

-- | Return bits 8-15 of the register e.g. rax -> ah
reg_high8 :: X86Reg R.GP -> Location addr (BVType 8)
reg_high8 r = subRegister n8 n8 r

rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi :: Location addr (BVType 64)
rax = fullRegister R.RAX
rcx = fullRegister R.RCX
rdx = fullRegister R.RDX
rbx = fullRegister R.RBX
rsp = fullRegister R.RSP
rbp = fullRegister R.RBP
rsi = fullRegister R.RSI
rdi = fullRegister R.RDI

eax :: Location addr (BVType 32)
eax = reg_low32 R.RAX

ebx :: Location addr (BVType 32)
ebx = reg_low32 R.RBX

ecx :: Location addr (BVType 32)
ecx = reg_low32 R.RCX

edx :: Location addr (BVType 32)
edx = reg_low32 R.RDX

ax :: Location addr (BVType 16)
ax = reg_low16 R.RAX

bx :: Location addr (BVType 16)
bx = reg_low16 R.RBX

cx :: Location addr (BVType 16)
cx = reg_low16 R.RCX

dx :: Location addr (BVType 16)
dx = reg_low16 R.RDX

al :: Location addr (BVType 8)
al = reg_low8 R.RAX

dl :: Location addr (BVType 8)
dl = reg_low8 R.RDX

ah :: Location addr (BVType 8)
ah = reg_high8 R.RAX

rip :: Location addr (BVType 64)
rip = fullRegister R.X86_IP

------------------------------------------------------------------------

packWord :: forall m n. (Semantics m, 1 <= n) => R.BitPacking n -> m (Value m (BVType n))
packWord (R.BitPacking sz bits) = do
  let getMoveBits :: R.BitConversion n -> m (Value m (BVType n))
      getMoveBits (R.ConstantBit b off) =
        return $ bvLit sz (if b then 1 `Bits.shiftL` widthVal off else (0 :: Integer))
      getMoveBits (R.RegisterBit reg off) = do
        v <- uext sz <$> get (fullRegister reg)
        return $ v `bvShl` bvLit sz (natValue off)
  injs <- mapM getMoveBits bits
  return (foldl1 (.|.) injs)

unpackWord :: forall m n. (Semantics m, 1 <= n) => R.BitPacking n -> Value m (BVType n) -> m ()
unpackWord (R.BitPacking sz bits) v = mapM_ unpackOne bits
  where
    unpackOne :: R.BitConversion n -> m ()
    unpackOne R.ConstantBit{}         = return ()
    unpackOne (R.RegisterBit reg off) = do
      let res_w = typeWidth reg
      fullRegister reg .= bvTrunc res_w (v `bvShr` bvLit sz (natValue off))

------------------------------------------------------------------------
-- Values

-- | @IsValue@ is a class used to define expressions.
--
-- The @IsValue@ operations have BIG-ENDIAN semantics: the higher
-- order bits are on the left. So, for example, a left shift makes a
-- number large (ignoring truncation), a right shift makes a number
-- smaller, and the first argument to concatenation becomes the
-- high-order bits in the result.
class IsValue (v  :: Type -> *) where

  -- | Returns the width of a bit-vector value.
  bv_width :: v (BVType n) -> NatRepr n

  -- | Choose a value based upon the boolean (basically a pure if then else)
  mux :: v BoolType -> v tp -> v tp -> v tp

  -- | Construct a literal bit vector.  The result is undefined if the
  -- literal does not fit withint the given number of bits.
  bvLit :: 1 <= n => NatRepr n -> Integer -> v (BVType n)

  -- | Add two bitvectors together dropping overflow.
  bvAdd :: 1 <= n => v (BVType n) -> v (BVType n) -> v (BVType n)

  -- | Subtract two vectors, ignoring underflow.
  bvSub :: 1 <= n => v (BVType n) -> v (BVType n) -> v (BVType n)

  -- | Performs a multiplication of two bitvector values.
  bvMul :: (1 <= n) => v (BVType n) -> v (BVType n) -> v (BVType n)

  -- | 2's complement
  bvNeg :: (1 <= n) => v (BVType n) -> v (BVType n)
  bvNeg n = bvLit (bv_width n) 0 `bvSub` n

  -- | Bitwise complement
  bvComplement :: (1 <= n) => v (BVType n) -> v (BVType n)

  -- | Bitwise and
  (.&.) :: (1 <= n) => v (BVType n) -> v (BVType n) -> v (BVType n)

  -- | Bitwise or
  (.|.) :: (1 <= n) => v (BVType n) -> v (BVType n) -> v (BVType n)

  -- | Exclusive or
  bvXor :: (1 <= n) => v (BVType n) -> v (BVType n) -> v (BVType n)

  -- | Equality
  (.=.) :: (1 <= n) => v (BVType n) -> v (BVType n) -> v BoolType
  bv .=. bv' = is_zero (bv `bvXor` bv')

  -- | Inequality
  (.=/=.) :: (1 <= n) => v (BVType n) -> v (BVType n) -> v BoolType
  bv .=/=. bv' = boolNot (bv .=. bv')

  -- | Return true if value is zero.
  is_zero :: (1 <= n) => v (BVType n) -> v BoolType
  is_zero x = x .=. bvLit (bv_width x) (0::Integer)

  -- | Concatentates two bit vectors.
  --
  -- Big-endian, so higher-order bits come from first argument.
  bvCat :: forall m n . (1 <= m, 1 <= n) => v (BVType m) -> v (BVType n) -> v (BVType (m + n))
  bvCat h l =
    case _1_le_m_plus_n of
      LeqProof -> go
    where
      -- GHC 7.10 has a context stack overflow related to @1 <= m + n@
      -- which goes away when we factor the body out like this.
      go :: (1 <= m + n) => v (BVType (m + n))
      go =
        case ( m_le_m_plus_n , n_le_m_plus_n , _1_le_m_plus_n ) of
          (LeqProof, LeqProof, LeqProof) ->
            let highOrderBits =
                  uext m_plus_n h `bvShl` bvLit m_plus_n (natValue $ n)
                lowOrderBits = uext m_plus_n l
            in highOrderBits .|. lowOrderBits

      m :: NatRepr m
      m = bv_width h

      n :: NatRepr n
      n = bv_width l

      m_plus_n :: NatRepr (m + n)
      m_plus_n = addNat m n

      m_le_m_plus_n :: LeqProof m (m + n)
      m_le_m_plus_n = addIsLeq m n

      n_le_m_plus_n :: LeqProof n (m + n)
      n_le_m_plus_n = addPrefixIsLeq m n

      _1_le_m_plus_n :: LeqProof 1 (m + n)
      _1_le_m_plus_n =
        leqAdd (LeqProof :: LeqProof 1 m) n

  -- | Splits a bit vectors into two.
  --
  -- Big-endian, so higher-order bits make up first component of
  -- result.
  bvSplit :: forall n . (1 <= n) => v (BVType (n + n)) -> (v (BVType n), v (BVType n))
  bvSplit v =
    let sz = halfNat (bv_width v) :: NatRepr n
     in case leqAdd (LeqProof :: LeqProof 1 n) sz :: LeqProof 1 (n + n) of
          LeqProof ->
            case leqAdd (leqRefl sz) sz :: LeqProof n (n + n) of
              LeqProof ->
                let sh = bvLit (bv_width v) (natValue sz)
                 in (bvTrunc sz (v `bvShr` sh), bvTrunc sz v)

  -- | Vectorization
  bvVectorize :: forall k n
               . (1 <= k, 1 <= n)
              => NatRepr k
              -> v (BVType n)
              -> [v (BVType k)]
  bvVectorize sz bv
    | Just Refl <- testEquality (bv_width bv) sz = [bv]
    | Just LeqProof <- testLeq sz (bv_width bv) =
        let bvs2n :: [v (BVType (k+k))] -- solve for size (n+n), then split into size n
            bvs2n = withLeqProof (dblPosIsPos (LeqProof :: LeqProof 1 k)) $
              bvVectorize (addNat sz sz) bv
        in concatMap (\v -> let (a, b) = bvSplit v in [a, b]) bvs2n
  bvVectorize _ _ = error "Unhandled case"

  -- | Given a list of values this concatenates them together
  bvUnvectorize :: forall k n. (1 <= k) => NatRepr n -> [v (BVType k)] -> v (BVType n)
  bvUnvectorize sz [x]
    | Just Refl <- testEquality (bv_width x) sz = x
  bvUnvectorize sz bvs = withLeqProof (dblPosIsPos (LeqProof :: LeqProof 1 k)) $
      bvUnvectorize sz $ concatBVPairs bvs
    where concatBVPairs :: (1 <= o) => [v (BVType o)] -> [v (BVType (o+o))]
          concatBVPairs (x:y:zs) = (x `bvCat` y) : concatBVPairs zs
          concatBVPairs _ = []


  vectorize2 :: (1 <= k, 1 <= n)
             => NatRepr k
             -> (v (BVType k) -> v (BVType k) -> v (BVType k))
             -> v (BVType n) -> v (BVType n)
             -> v (BVType n)
  vectorize2 sz op x y = let xs = bvVectorize sz x
                             ys = bvVectorize sz y
                         in bvUnvectorize (bv_width x) $ zipWith op xs ys

  -- | Rotations
  bvRol :: (1 <= n) => v (BVType n) -> v (BVType n) -> v (BVType n)
  bvRol v n = bvShl v n .|. bvShr v bits_less_n
    where
      bits_less_n = bvSub (bvLit (bv_width v) (natValue $ bv_width v)) n

  bvRor :: (1 <= n) => v (BVType n) -> v (BVType n) -> v (BVType n)
  bvRor v n = bvShr v n .|. bvShl v bits_less_n
    where
      bits_less_n = bvSub (bvLit (bv_width v) (natValue $ bv_width v)) n

  -- | Shifts, the semantics is undefined for shifts >= the width of the first argument.
  --
  -- The first argument is the value to shift, and the second argument
  -- is the number of bits to shift by.
  --
  -- Big-endian, so left shift moves bits to higher-order positions
  -- and right shift moves bits to lower-order positions.
  bvShr, bvSar, bvShl :: 1 <= n => v (BVType n) -> v (BVType n) -> v (BVType n)

  -- | Truncate the value.
  --
  -- Returns 'm' lower order bits.
  bvTrunc :: (1 <= m, m <= n) => NatRepr m -> v (BVType n) -> v (BVType m)
  bvTrunc w e =
    case testStrictLeq w (bv_width e) of
      Left LeqProof -> bvTrunc' w e
      Right Refl -> e

  -- | Version of 'bvTrunc' that precludes trivial truncations; see
  -- 'uext'' docs.
  bvTrunc' :: (1 <= m, m+1 <= n) => NatRepr m -> v (BVType n) -> v (BVType m)

  -- | Truncate the value.
  --
  -- Drops the 'm' low order bits.
  bvDrop :: forall m n.
    (1 <= n, 1 <= n - m, n - m <= n, m <= n) =>
    NatRepr m -> v (BVType n) -> v (BVType (n - m))
  bvDrop m v = bvTrunc (subNat n m) $ v `bvShr` (bvLit n (natValue m))
    where
      n :: NatRepr n
      n = bv_width v

  -- | Unsigned less than or equal.
  bvUle :: v (BVType n) -> v (BVType n) -> v BoolType
  bvUle x y = boolNot (bvUlt y x)

  -- | Unsigned less than
  bvUlt :: v (BVType n) -> v (BVType n) -> v BoolType

  -- | Signed less than
  bvSlt :: (1 <= n) => v (BVType n) -> v (BVType n) -> v BoolType

  -- | Returns bit at index given by second argument, 0 being lsb
  -- If the bit index is greater than or equal to n, then the result is zero.
  bvBit :: (1 <= n) => v (BVType n) -> v (BVType n) -> v BoolType

  -- | Return most significant bit of number.
  msb :: (1 <= n) => v (BVType n) -> v BoolType
  msb v = bvSlt v (bvLit (bv_width v) (0::Integer))
--  msb v = bvBit v (bvLit (bv_width v) (natValue (bv_width v) - 1))
     -- FIXME: should be log2 (bv_width v) here

  -- | Perform a signed extension of a bitvector.
  sext :: forall m n . (1 <= m, m <= n) => NatRepr n -> v (BVType m) -> v (BVType n)
  sext w e =
    case ( testStrictLeq (bv_width e) w
         , leqTrans (LeqProof :: LeqProof 1 m) (LeqProof :: LeqProof m n)
         ) of
      (Left LeqProof, LeqProof) -> sext' w e
      (Right Refl,_) -> e

  -- | Version of 'sext' that precludes trivial extensions; see
  -- 'uext'' docs.
  sext' :: (1 <= m, m+1 <= n, 1 <= n) => NatRepr n -> v (BVType m) -> v (BVType n)

  -- | Perform a unsigned extension of a bitvector.
  --
  -- Unlike 'uext' below, this is a strict extension: the 'm+1 <= n'
  -- means 'm < n'.
  --
  -- We have this strict version because constructors which reify
  -- these ops, e.g. @App@ in Reopt and Crucible, are strict in this
  -- sense.
  uext' :: (1 <= m, m+1 <= n, 1 <= n) => NatRepr n -> v (BVType m) -> v (BVType n)

  -- | Perform a unsigned extension of a bitvector.
  uext :: forall m n
        . (1 <= m, m <= n)
        => NatRepr n
        -> v (BVType m)
        -> v (BVType n)
  uext w e =
    case ( testStrictLeq (bv_width e) w
         , leqTrans (LeqProof :: LeqProof 1 m) (LeqProof :: LeqProof m n)
         ) of
      (Left LeqProof, LeqProof) ->
        uext' w e
      (Right Refl,_) -> e

  -- | Return least-significant nibble (4 bits).
  least_nibble :: forall n . (4 <= n) => v (BVType n) -> v (BVType 4)
  least_nibble = bvTrunc knownNat

  -- | Return least-significant byte.
  least_byte :: forall n . (8 <= n) => v (BVType n) -> v (BVType 8)
  least_byte = bvTrunc knownNat

  -- | Return true if value contains an even number of true bits.
  even_parity :: v (BVType 8) -> v BoolType

  -- | Reverse the bytes in a bitvector expression.
  -- The parameter n should be a multiple of 8.
  reverse_bytes :: (1 <= n) => v (BVType n) -> v (BVType n)

  -- | Return true expression is signed add overflows.  See
  -- @sadc_overflows@ for definition.
  sadd_overflows :: (1 <= n) => v (BVType n) -> v (BVType n) -> v BoolType
  sadd_overflows x y = sadc_overflows x y false

  -- | Return true expression is unsigned add overflows.  See
  -- @sadc_overflows@ for definition.
  uadd_overflows :: v (BVType n) -> v (BVType n) -> v BoolType
  uadd_overflows x y = uadc_overflows x y false

  -- | Return true expression if a signed add-with carry would overflow.
  -- This holds if the sign bits of the arguments are the same, and the sign
  -- of the result is different.
  sadc_overflows :: v (BVType n) -> v (BVType n) -> v BoolType -> v BoolType

  -- | Return true expression if a unsigned add-with carry would overflow.
  uadc_overflows :: v (BVType n) -> v (BVType n) -> v BoolType -> v BoolType

  -- | Return true expression if unsigned sub overflows.
  -- @usub_overflows x y@ is true when @x - y@ (interpreted as unsigned numbers),
  -- would return a negative result.
  usub_overflows :: (1 <= n) => v (BVType n) -> v (BVType n) -> v BoolType
  usub_overflows x y = usbb_overflows x y false

  -- | Return true expression is signed sub overflows.
  ssub_overflows :: (1 <= n) => v (BVType n) -> v (BVType n) -> v BoolType
  ssub_overflows x y = ssbb_overflows x y false

  -- | Return true expression if unsigned sbb overflows.
  -- @usbb_overflows x y c@ is true when @x - (y+c)@ with
  -- x,y interpreted as unsigned numbers and c a borrow bit,
  -- would return a negative result.
  usbb_overflows :: (1 <= n)
                 => v (BVType n)
                 -> v (BVType n)
                 -> v BoolType
                 -> v BoolType

  -- | Return true expression if unsigned sub overflows.
  -- @ssbb_overflows x y c@ is true when @x - (y+c)@ with
  -- x,y interpreted as signed numbers and c a borrow bit,
  -- would return a number different from the expected integer due to
  -- wrap-around.
  ssbb_overflows :: (1 <= n)
                 => v (BVType n)
                 -> v (BVType n)
                 -> v BoolType
                 -> v BoolType

  -- | bsf "bit scan forward" returns the index of the least-significant
  -- bit that is 1.  Undefined if value is zero.
  -- All bits at indices less than return value must be unset.
  bsf :: (1 <= n) => v (BVType n) -> v (BVType n)

  -- | bsr "bit scan reverse" returns the index of the most-significant
  -- bit that is 1.  Undefined if value is zero.
  -- All bits at indices greater than return value must be unset.
  bsr :: (1 <= n) => v (BVType n) -> v (BVType n)

  -- FP stuff

  -- | is NaN (quiet and signalling)
  isQNaN :: FloatInfoRepr flt -> v (FloatType flt) -> v BoolType
  isSNaN :: FloatInfoRepr flt -> v (FloatType flt) -> v BoolType

  isNaN :: FloatInfoRepr flt -> v (FloatType flt) -> v BoolType
  isNaN fir v = boolOr (isQNaN fir v) (isSNaN fir v)

  -- | Add two floating point numbers.
  -- This can throw exceptions, including:
  -- #IA Operand is an SNaN value or unsupported format.
  --     Operands are infinities of unlike sign.
  -- #D  Source operand is a denormal value.
  -- #U  Result is too small for destination format.
  -- #O  Result is too large for destination format.
  -- #P  Value cannot be represented exactly in destination format.
  fpAdd :: FloatInfoRepr flt
        -> v (FloatType flt)
        -> v (FloatType flt)
        -> v (FloatType flt)

  -- | Indicates whether floating point representation from addition is
  -- larger than the actual value.
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpAddRoundedUp :: FloatInfoRepr flt
                 -> v (FloatType flt)
                 -> v (FloatType flt)
                 -> v BoolType

  -- | Subtracts one floating point numbers from another.
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpSub :: FloatInfoRepr flt
        -> v (FloatType flt)
        -> v (FloatType flt)
        -> v (FloatType flt)

  -- | Indicates whether floating point representation from subtraction
  -- is larger than the actual value.
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpSubRoundedUp :: FloatInfoRepr flt
                 -> v (FloatType flt)
                 -> v (FloatType flt)
                 -> v BoolType

  -- | Multiplies two floating point numbers.
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpMul :: FloatInfoRepr flt -> v (FloatType flt) -> v (FloatType flt) -> v (FloatType flt)

  -- | Whether the result of the mul was rounded up
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpMulRoundedUp :: FloatInfoRepr flt -> v (FloatType flt) -> v (FloatType flt) -> v BoolType

  -- | Divides two floating point numbers.
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpDiv :: FloatInfoRepr flt -> v (FloatType flt) -> v (FloatType flt) -> v (FloatType flt)

  -- | Compare if one floating is strictly less than another.
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpLt :: FloatInfoRepr flt -> v (FloatType flt) -> v (FloatType flt) -> v BoolType

  -- | Floating point equality (equates -0 and 0)
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpEq :: FloatInfoRepr flt -> v (FloatType flt) -> v (FloatType flt) -> v BoolType
  fpEq fir v v' = boolNot $ boolOr (fpLt fir v v') (fpLt fir v' v)

  -- | Convert between floating point values
  -- TODO: Describe exceptions or modify usage to avoid them.
  fpCvt :: FloatInfoRepr flt -> FloatInfoRepr flt' -> v (FloatType flt) -> v (FloatType flt')

  -- | Whether roundup occurs when converting between FP formats
  fpCvtRoundsUp :: FloatInfoRepr flt -> FloatInfoRepr flt' -> v (FloatType flt) -> v BoolType

  -- | Convert a signed integer to a float. (e.g. 255 -> 255.0)
  -- (see x86_64 CVTSI2SD instruction)
  -- We assume that the floating point representation is large enough to hold
  -- all the values at that bitwidth.
  fpFromBV :: FloatInfoRepr flt -> v (BVType n) -> v (FloatType flt)

  -- | Convert a floating point value to a signed integer.
  -- * If the conversion is inexact, then the value is truncated to zero.
  -- * If the conversion is out of the range of the bitvector, then a
  --   floating point exception should be raised.
  -- * If that exception is masked, then this returns -1 (as a signed bitvector).
  truncFPToSignedBV :: (1 <= n)
                    => NatRepr n
                    -> FloatInfoRepr flt
                    -> v (FloatType flt)
                    -> v (BVType n)


  true :: v BoolType
  true = boolValue True

  false :: v BoolType
  false = boolValue True

  boolValue :: Bool -> v BoolType

  boolNot :: v BoolType -> v BoolType

  boolAnd :: v BoolType -> v BoolType -> v BoolType
  boolOr :: v BoolType -> v BoolType -> v BoolType
  boolEq  :: v BoolType -> v BoolType -> v BoolType
  boolXor :: v BoolType -> v BoolType -> v BoolType

(.&&.) :: IsValue v => v BoolType -> v BoolType -> v BoolType
(.&&.) = boolAnd

(.||.) :: IsValue v => v BoolType -> v BoolType -> v BoolType
(.||.) = boolOr

-- | Construct a literal bit vector.  The result is undefined if the
-- literal does not fit withint the given number of bits.
bvKLit :: (IsValue v, KnownNat n, 1 <= n) => Integer -> v (BVType n)
bvKLit = bvLit knownNat

-- | Add two bitvectors together dropping overflow.
(.+) :: (1 <= n, IsValue v) => v (BVType n) -> v (BVType n) -> v (BVType n)
(.+) = bvAdd

-- | Subtract two vectors, ignoring underflow.
(.-) :: (1 <= n, IsValue v) => v (BVType n) -> v (BVType n) -> v (BVType n)
(.-) = bvSub

-- | Performs a multiplication of two bitvector values.
(.*) :: (1 <= n, IsValue v) => v (BVType n) -> v (BVType n) -> v (BVType n)
(.*) = bvMul

infixl 7 .*
infixl 6 .+
infixl 6 .-
infix  4 .=

------------------------------------------------------------------------
-- Monadic definition

-- | This returns the type associated with values that can be read
-- for the semantics monad.
type family Value (m :: * -> *) :: Type -> *

type Pred m = Value m BoolType
type BVValue m w = Value m (BVType w)

type MLocation m = Location (Value m (BVType 64))

data ExceptionClass
   = DivideError -- #DE
   | FloatingPointError
   | SIMDFloatingPointException
   | GeneralProtectionException Int
   | UndefinedInstructionError -- basically for ud2
     -- ^ A general protection exception with the given error code.
     -- -- | AlignmentCheck
  deriving (Eq, Ord, Show)

-- | Primitive instructions.
--
-- A primitive instruction is one whose semantics depend on the
-- underlying hardware or OS.
data Primitive
   = Syscall
   | CPUID
   | RDTSC
   -- | The semantics of @xgetbv@ seems to depend on the semantics of @cpuid@.
   | XGetBV
  deriving (Eq, Show)

instance Pretty Primitive where
  pretty = text . map toLower . show

------------------------------------------------------------------------
-- SIMDWidth

-- | Defines a width of a register associated with SIMD operations
-- (e.g., MMX, XMM, AVX)
data SIMDWidth w
   = (w ~  64) => SIMD_64
   | (w ~ 128) => SIMD_128
   | (w ~ 256) => SIMD_256

-- | Return the 'NatRepr' associated with the given width.
instance HasRepr SIMDWidth NatRepr where
  typeRepr SIMD_64  = knownNat
  typeRepr SIMD_128 = knownNat
  typeRepr SIMD_256 = knownNat

------------------------------------------------------------------------
-- RepValSize

-- | Rep value
data RepValSize w
   = (w ~  8) => ByteRepVal
   | (w ~ 16) => WordRepVal
   | (w ~ 32) => DWordRepVal
   | (w ~ 64) => QWordRepVal

repValHasSupportedWidth :: RepValSize w -> (SupportedBVWidth w => a) -> a
repValHasSupportedWidth rval x =
  case rval of
    ByteRepVal  -> x
    WordRepVal  -> x
    DWordRepVal -> x
    QWordRepVal -> x

repValSizeMemRepr :: RepValSize w -> MemRepr (BVType w)
repValSizeMemRepr v =
  case v of
    ByteRepVal  -> BVMemRepr (knownNat :: NatRepr 1) LittleEndian
    WordRepVal  -> BVMemRepr (knownNat :: NatRepr 2) LittleEndian
    DWordRepVal -> BVMemRepr (knownNat :: NatRepr 4) LittleEndian
    QWordRepVal -> BVMemRepr (knownNat :: NatRepr 8) LittleEndian

repValSizeByteCount :: RepValSize w -> Integer
repValSizeByteCount = memReprBytes . repValSizeMemRepr

------------------------------------------------------------------------
-- Semantics

-- | The Semantics Monad defines all the operations needed for the x86
-- semantics.
class ( Applicative m
      , Monad m
      , IsValue (Value m)
      ) => Semantics m where

  -- | Create a fresh "undefined" value.
  make_undefined :: TypeRepr tp -> m (Value m tp)

  -- | Mark a Boolean variable as undefined.
  set_undefined :: KnownType tp => MLocation m tp -> m ()
  set_undefined l = do
    u <- make_undefined knownType
    l .= u

  -- | Read from the given location.
  get :: MLocation m tp -> m (Value m tp)
  -- | Assign a value to alocation.
  (.=) :: MLocation m tp -> Value m tp -> m ()

  -- | Modify the value at a location
  modify :: MLocation m tp -> (Value m tp -> Value m tp) -> m ()
  modify r f = do
    x <- get r
    r .= f x

  -- | Perform an if-then-else
  ifte_ :: Value m BoolType -> m () -> m () -> m ()

  -- | Run a step if condition holds.
  when_ :: Value m BoolType -> m () -> m ()
  when_ p x = ifte_ p x (return ())

  -- | Run a step if condition is false.
  unless_ :: Value m BoolType -> m () -> m ()
  unless_ p = ifte_ p (return ())

  -- FIXME: use location instead?
  -- | Move n bits at a time, with count moves
  --
  -- Semantic sketch. The effect on memory should be like @memcopy@
  -- below, not like @memcopy2@. These sketches ignore the issue of
  -- copying in chunks of size `bytes`, which should only be an
  -- efficiency concern.
  --
  -- @
  -- void memcopy(int bytes, int copies, char *src, char *dst, int reversed) {
  --   int maybeFlip = reversed ? -1 : 1;
  --   for (int c = 0; c < copies; ++c) {
  --     for (int b = 0; b < bytes; ++b) {
  --       int offset = maybeFlip * (b + c * bytes);
  --       *(dst + offset) = *(src + offset);
  --     }
  --   }
  -- }
  -- @
  --
  -- Compare with:
  --
  -- @
  -- void memcopy2(int bytes, int copies, char *src, char *dst, int reversed) {
  --   int maybeFlip = reversed ? -1 : 1;
  --   /* The only difference from `memcopy` above: here the same memory is
  --      copied whether `reversed` is true or false -- only the order of
  --      copies changes -- whereas above different memory is copied for
  --      each direction. */
  --   if (reversed) {
  --     /* Start at the end and work backwards. */
  --     src += copies * bytes - 1;
  --     dst += copies * bytes - 1;
  --   }
  --   for (int c = 0; c < copies; ++c) {
  --     for (int b = 0; b < bytes; ++b) {
  --       int offset = maybeFlip * (b + c * bytes);
  --       *(dst + offset) = *(src + offset);
  --     }
  --   }
  -- }
  -- @
  memcopy :: Integer
             -- ^ Number of bytes to copy at a time (1,2,4,8)
          -> Value m (BVType 64)
             -- ^ Number of values to move.
          -> Value m (BVType 64)
             -- ^ Start of source buffer
          -> Value m (BVType 64)
             -- ^ Start of destination buffer.
          -> Value m BoolType
             -- ^ Flag indicates direction of move:
             -- True means we should decrement buffer pointers after each copy.
             -- False means we should increment the buffer pointers after each copy.
          -> m ()

  -- | Compare the memory regions.  Returns the number of elements which are
  -- identical.  If the direction is 0 then it is increasing, otherwise decreasing.
  --
  -- See `memcopy` above for explanation of which memory regions are
  -- compared: the regions copied there are compared here.
  memcmp :: Integer
            -- ^ Number of bytes to compare at a time {1, 2, 4, 8}
            -> Value m (BVType 64)
            -- ^ Number of elementes to compare
            -> Value m (BVType 64)
            -- ^ Pointer to first buffer
            -> Value m (BVType 64)
            -- ^ Pointer to second buffer
            -> Value m BoolType
             -- ^ Flag indicates direction of copy:
             -- True means we should decrement buffer pointers after each copy.
             -- False means we should increment the buffer pointers after each copy.
            -> m (Value m (BVType 64))

  -- | Set memory to the given value, for the number of words (nbytes
  -- = count * bv_width v)
  memset :: (1 <= n)
         => Value m (BVType 64)
            -- ^ Number of values to set
         -> Value m (BVType n)
            -- ^ Value to set
         -> Value m (BVType 64)
            -- ^ Pointer to buffer to set
         -> Value m BoolType
            -- ^ Direction flag
         -> m ()

  -- | This will compare a value against the contents of a memory region for equality and/or
  -- inequality.
  --
  -- It accepts the value to compare, a pointer to the start of the region, and
  -- the maximum number of elements to compare, which is decremented after each comparison.
  -- It returns the value of the count after it has succeeded, or zero if we reached the
  -- end without finding a value.   A return value of zero is thus ambiguous on whether
  -- the value was found in the last iteration, or whether the value was never found.
  rep_scas :: Bool
              -- ^ Find first matching (True) or not matching (False)
           -> Value m BoolType
              -- ^ Flag indicates direction of search
              -- True means we should decrement buffer pointers after each copy.
              -- False means we should increment the buffer pointers after each copy.
           -> RepValSize w
              -- ^ Number of bytes to compare at a time {1, 2, 4, 8}
           -> Value m (BVType w)
              -- ^ Value to compare
           -> Value m (BVType 64)
              -- ^ Pointer to first buffer
           -> Value m (BVType 64)
              -- ^ Maximum number of elementes to compare
           -> m (Value m (BVType 64))


  -- | execute a primitive instruction.
  primitive :: Primitive -> m ()


  -- | Store floating point control word in given address.
  fnstcw :: Value m (BVType 64) -> m ()


  -- | @pshufb w x s@ returns a value @res@ generated from the bytes of @x@
  -- based on indices defined in the corresponding bytes of @s@.
  --
  -- Let @n@ be the number of bytes in the width @w@, and let @l = log2(n)@.
  -- Given a byte index @i@, the value of byte @res[i]@, is defined by
  --   @res[i] = 0 if msb(s[i]) == 1@
  --   @res[i] = x[j] where j = s[i](0..l)
  -- where @msb(y)@ returns the most-significant bit in byte @y@.
  pshufb :: (1 <= w)
         => SIMDWidth w
         -> Value m (BVType w)
         -> Value m (BVType w)
         -> m (Value m (BVType w))

  -- | Return the base address of the given segment.
  getSegmentBase :: Segment -> m (Value m (BVType 64))

  -- | Unsigned division.
  --
  -- The x86 documentation for @div@ (Intel x86 manual volume 2A,
  -- page 3-393) says that results should be truncated towards
  -- zero. These operations are called @quot@ and @rem@ in Haskell,
  -- whereas @div@ and @mod@ in Haskell round towards negative
  -- infinity.
  --
  -- This should raise a #DE exception if the denominator is zero or the
  -- result is larger than maxUnsigned n.
  bvQuotRem :: (1 <= w)
            => RepValSize w
            -> Value m (BVType (w+w))
               -- ^ Numerator
            -> Value m (BVType w)
               -- ^ Denominator
            -> m (BVValue m w, BVValue m w)

  -- | Signed division.
  --
  -- The x86 documentation for @idiv@ (Intel x86 manual volume 2A,
  -- page 3-393) says that results should be truncated towards
  -- zero. These operations are called @quot@ and @rem@ in Haskell,
  -- whereas @div@ and @mod@ in Haskell round towards negative
  -- infinity.
  --
  -- This should raise a #DE exception if the denominator is zero or the
  -- result is larger than maxSigned n or less than minSigned n.
  bvSignedQuotRem :: (1 <= w)
                  => RepValSize w
                  -> Value m (BVType (w+w))
                     -- ^ Numerator
                  -> Value m (BVType w)
                     -- ^ Denominator
                  -> m (BVValue m w, BVValue m w)

  -- | raises an exception if the predicate is true and the mask is false
  exception :: Value m BoolType    -- mask
            -> Value m BoolType -- predicate
            -> ExceptionClass
            -> m ()

  -- FIXME: those should also mutate the underflow/overflow flag and
  -- related state.

  -- | X87 support --- these both affect the register stack for the
  -- x87 state.
  x87Push :: Value m (FloatType X86_80Float) -> m ()
  x87Pop  :: m ()

-- | Defines operations that need to be supported at a specific bitwidht.
type SupportedBVWidth n
   = ( 1 <= n
     , 4 <= n
     , 8 <= n
     , KnownNat n
     )

-- | @IsLocationBV m n@ is a constraint used to indicate that @m@
-- implements Semantics, and @Value m (BV n)@ supports the operations
-- used to assign registers.
type IsLocationBV m n
   = ( SupportedBVWidth n
     , Semantics m
     )