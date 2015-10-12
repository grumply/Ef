{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
module Effect.Loop
  ( loop, Loop
  , loops, Loops
  ) where

import Mop
import Data.Function
import Unsafe.Coerce

data Loop k
  = FreshScope (Integer -> k)
  | forall s. Continue Integer s
  | forall a. Break Integer a

data Loops k = Loops Integer k

freshScope :: Has Loop fs m => Plan fs m Integer
freshScope = symbol (FreshScope id)

loop :: forall fs m s a. Has Loop fs m
     => s
     -> (    (forall b. a -> Plan fs m b)
          -> (forall b. s -> Plan fs m b)
          -> s
          -> Plan fs m a
        )
     -> Plan fs m a
loop s0 x = do
    scope <- freshScope
    let break a      = symbol (Break scope a)
        continue s   = symbol (Continue scope s)
        loopBody r s = reifyLoop r scope (x break continue s)
    fix loopBody s0

reifyLoop :: Has Loop symbols m
          => (b -> Plan symbols m a)
          -> Integer
          -> Plan symbols m a
          -> Plan symbols m a
reifyLoop restart scope =
  mapStep $ \go (Step syms bp) ->
    let step = Step syms (\b -> go (bp b))
        handle (Continue i s)
          | i == scope = restart (unsafeCoerce s)
          | otherwise = step
        handle (Break i a)
          | i == scope = Pure (unsafeCoerce a)
          | otherwise = step
        handle _ = step
    in maybe step handle (prj syms)

loops :: Uses Loops gs m
      => Instruction Loops gs m
loops = Loops 0 $ \fs ->
  let Loops i k = view fs
  in instruction (Loops (succ i) k) fs

instance Pair Loops Loop where
  pair p (Loops i k) (FreshScope ik) = p k (ik i)
  pair _ _ _ = error "Unscoped looping construct."