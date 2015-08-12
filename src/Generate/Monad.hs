{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Generate.Monad
  (Mop(..),MopContext(..),MopState(..)
  ,Verbosity(..)
  ,Log(..)
  ,io,liftTH
  ,log,errorAt
  ,sourceDirectories
  ,module Export
  ) where

import Control.Monad.Reader as Export
import Control.Monad.State  as Export
import Control.Monad.Writer as Export hiding (Alt(..))

import Data.Data
import qualified Data.Map as Map

import System.Exit

import Distribution.PackageDescription

import Language.Haskell.Exts as Export
import Language.Haskell.Exts.Pretty as Export

-- explicitly avoid exporting both L.H.E and L.H.TH

import qualified Language.Haskell.TH as TH
import qualified Language.Haskell.TH.Syntax as TH

import Generate.Derives()

import Prelude hiding (log)

-- Simple example approach to package management.

-- data BucketName = BucketName String
--   deriving (Show,Read,Eq,Data,Typeable)

-- data BucketVersion = BucketVersion Version
--   deriving (Show,Read,Eq,Data,Typeable)

-- data BucketConfiguration = BucketConfiguration
--   { bucketName         :: BucketName
--   , bucketVersion      :: BucketVersion
--   } deriving (Show,Read,Eq,Data,Typeable)

-- data Bucket = Bucket
--   { bucketConfig        :: BucketConfiguration
--   , bucketAlgebras      :: [HSE.Module]
--   , bucketCoalgebras    :: [HSE.Module]
--   , bucketInstructions  :: [HSE.Module]
--   , bucketInterpreters  :: [HSE.Module]
--   , bucketPairings      :: [HSE.Module]
--   , bucketOtherModules  :: [HSE.Module]
--   } deriving (Show,Read,Eq,Data,Typeable)
-- type Buckets = [Bucket]

data Log
  = Alert    String
  | Critical String
  | Error    String
  | Warning  String
  | Notify   String
  | Info     String
  | Debug    String
  deriving (Show,Ord,Eq,Data,Typeable)

data Verbosity
  = ReallySilent -- ^   Nothing
  | Silent       -- ^ < Warning; default
  | Quiet        -- ^ < Info
  | Normal       -- ^ < Debug
  | Loud         -- ^   All
  deriving (Read,Show,Eq,Ord,Enum,Data,Typeable)

data MopContext = MopContext
  { executionModule     :: TH.Module
  , location            :: TH.Loc
  , originalModule      :: Module
  , verbosity           :: Verbosity
  } deriving (Show,Read,Eq,Data,Typeable)

-- would like to include MopHistory, but prevents data/typeable
-- will tuple it up in StateT s in Mop execution context.
data MopState = MopState
  -- { currentBuckets      :: [Bucket]
  { currentPackageDesc  :: GenericPackageDescription
  , cabalFile           :: FilePath
  , currentModule       :: Module
  , changes             :: Map.Map FilePath [(Int,Either Int Int)]
  } deriving (Show,Read,Eq,Data,Typeable)

newtype Mop a = Mop
  { runMop :: WriterT [Log] (ReaderT MopContext (StateT MopState TH.Q)) a
  } deriving ( Functor
             , Applicative
             , Monad
             , MonadReader MopContext
             , MonadState  MopState
             , MonadWriter [Log]
             )

liftTH :: TH.Q a -> Mop a
liftTH f = Mop $ lift $ lift $ lift f

io :: IO a -> Mop a
io = liftTH . TH.runIO

log :: (String -> Log) -> String -> Mop ()
log x str = do
  when (x str < Info str) (io (print (x str)))
  tell [x str]

errorAt :: String -> Int -> Int -> Mop a
errorAt err beg end = do
  log Error $
    err ++ " between lines " ++ show beg ++ " and " ++ show end ++ "."
  io exitFailure

sourceDirectories :: Mop [FilePath]
sourceDirectories = do
  MopState pkg fp hsem ds <- get
  let pd = packageDescription pkg
      Just Library{..} = library pd
      BuildInfo{..} = libBuildInfo
  return hsSourceDirs
