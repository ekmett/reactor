{-# LANGUAGE DeriveDataTypeable #-}
module Reactor.Atomic where

import Control.Monad
import Control.Monad.IO.Class
import Data.Bits.Atomic
import Data.Data
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Storable
import System.IO.Unsafe

newtype Atomic a = Atomic (ForeignPtr a)
  deriving (Data, Typeable)

instance (Show a, Storable a) => Show (Atomic a) where
  showsPrec d (Atomic fp) = showsPrec d $ unsafePerformIO $ withForeignPtr fp peek

atomic :: (MonadIO m, AtomicBits a, Storable a) => a -> m (Atomic a)
atomic a = liftIO $ do
  fp <- mallocForeignPtr
  withForeignPtr fp $ \p -> poke p a
  return $ Atomic fp 

withAtomic :: MonadIO m => Atomic a -> (Ptr a -> IO b) -> m b
withAtomic (Atomic fp) = liftIO . withForeignPtr fp 
{-# INLINE withAtomic #-}

atomicFetchAndAdd :: (MonadIO m, AtomicBits a) => Atomic a -> a -> m a
atomicFetchAndAdd fp a = withAtomic fp $ \p -> fetchAndAdd p a
{-# INLINE atomicFetchAndAdd #-}

atomicFetchAndAnd :: (MonadIO m, AtomicBits a) => Atomic a -> a -> m a
atomicFetchAndAnd fp a = withAtomic fp $ \p -> fetchAndAnd p a
{-# INLINE atomicFetchAndAnd #-}
  
atomicFetch :: (MonadIO m, AtomicBits a) => Atomic a -> m a 
atomicFetch fp = atomicFetchAndAdd fp 0
{-# INLINE atomicFetch #-}

atomicFetchAndSub :: (MonadIO m, AtomicBits a) => Atomic a -> a -> m a
atomicFetchAndSub fp a = withAtomic fp $ \p -> fetchAndSub p a
{-# INLINE atomicFetchAndSub #-}

atomicSubAndFetch :: (MonadIO m, AtomicBits a) => Atomic a -> a -> m a
atomicSubAndFetch fp a = withAtomic fp $ \p -> subAndFetch p a
{-# INLINE atomicSubAndFetch #-}

atomicAddAndFetch :: (MonadIO m, AtomicBits a) => Atomic a -> a -> m a
atomicAddAndFetch fp a = withAtomic fp $ \p -> subAndFetch p a
{-# INLINE atomicAddAndFetch #-}

atomicCompareAndSwapBool :: (MonadIO m, AtomicBits a) => Atomic a -> a -> a -> m Bool
atomicCompareAndSwapBool fp old new = withAtomic fp $ \p -> compareAndSwapBool p old new
{-# INLINE atomicCompareAndSwapBool #-}

atomicCompareAndSwap :: (MonadIO m, AtomicBits a) => Atomic a -> a -> a -> m a
atomicCompareAndSwap fp old new = withAtomic fp $ \p -> compareAndSwap p old new
{-# INLINE atomicCompareAndSwap #-}

atomicLockTestAndSet :: (MonadIO m, AtomicBits a) => Atomic a -> m a
atomicLockTestAndSet fp = withAtomic fp lockTestAndSet
{-# INLINE atomicLockTestAndSet #-}

atomicLockRelease :: (MonadIO m, AtomicBits a) => Atomic a -> m ()
atomicLockRelease fp = withAtomic fp lockRelease
{-# INLINE atomicLockRelease #-}

given :: (MonadIO m, AtomicBits a) => Atomic a -> m () -> m ()
given flag task = do
    i <- atomicFetch flag
    when (i /= 0) task

clearing :: (MonadIO m, AtomicBits a) => Atomic a -> m () -> m ()
clearing flag task = do
    i <- atomicFetchAndAnd flag 0
    when (i /= 0) task

