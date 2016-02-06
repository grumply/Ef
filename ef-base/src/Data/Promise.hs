{- | A wrapper around MVar in a promise-y style. -}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE AutoDeriveTypeable #-}
module Data.Promise
    (
      -- * Promise
      Promise
    , newPromise
      
      -- * Ef Use
    , fulfill
    , fulfilled
    , demand

      -- * IO Creation and Use
    , newPromiseIO
    , fulfillIO
    , fulfilledIO
    , demandIO
    ) where


import Ef
import Ef.IO

import Control.Concurrent


-- | Promise represents a variable that:
--
--   (1) may be set only once with `fulfill` but does not block
--   2. may be polled with `fulfilled` for a value
--   3. may be blocked on with `demand` for a value
--   4. may be read many times with `demand`
--   5. may be shared across threads
newtype Promise result = Promise { getPromise :: MVar result }
    deriving Eq


-- | Construct a new un`fulfill`ed `Promise`.
newPromise :: (Monad super, Lift IO super)
           => Narrative self super (Promise result)
newPromise = io newPromiseIO


-- | Demand a `Promise`d value, blocking until it is fulfilled. Lifts
-- `BlockedIndefinitelyOnMVar` into the `Narrative` if the underlying
-- `demandIO` throws it when a `Promise` can never be `fulfill`ed.
demand :: (Monad super, Lift IO super)
       => Promise result -> Narrative self super result
demand = io . demandIO


-- | Fulfill a `Promise`. Returns a Bool where False
-- denotes that the `Promise` has already been fulfilled.
fulfill :: (Monad super, Lift IO super)
        => Promise result -> result -> Narrative self super Bool
fulfill = (io .) . fulfillIO


-- | Poll a `Promise` for the result of a `fulfill`. Does not block but instead
-- returns False if the `Promise` has already been `fulfill`ed.
fulfilled :: (Monad super, Lift IO super)
          => Promise result -> Narrative self super Bool
fulfilled = io . fulfilledIO


-- | Construct a new un`fulfill`ed `Promise` in IO.
newPromiseIO :: IO (Promise result)
newPromiseIO = Promise <$> newEmptyMVar


-- | Demand a `Promise`d value in IO, blocking until it is fulfilled.
demandIO :: Promise result -> IO result
demandIO = readMVar . getPromise


-- | Fulfill a `Promise` in IO. Returns a Bool where False
-- denotes that the `Promise` has already been fulfilled.
fulfillIO :: Promise result -> result -> IO Bool
fulfillIO (Promise p) = tryPutMVar p


-- | Poll a `Promise` for the result of a `fulfill` in IO. Does not block.
fulfilledIO :: Promise result -> IO Bool
fulfilledIO (Promise p) = isEmptyMVar p
