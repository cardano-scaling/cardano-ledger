{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Test.Shelley.Spec.Ledger.Generator.Block
  ( genBlock
  )
  where

import           Data.Foldable (toList)
import qualified Data.List as List (find)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (listToMaybe)
import           Data.Ratio (denominator, numerator, (%))
import           Test.QuickCheck (Gen)
import qualified Test.QuickCheck as QC (choose, discard, shuffle)

import           Byron.Spec.Ledger.Core (dom, range)
import           Cardano.Slotting.Slot (WithOrigin (..))
import           Control.State.Transition.Extended (TRC (..), applySTS)
import           Control.State.Transition.Trace.Generator.QuickCheck (sigGen)
import           Shelley.Spec.Ledger.BaseTypes (intervalValue)
import           Shelley.Spec.Ledger.BlockChain (LastAppliedBlock (..))
import           Shelley.Spec.Ledger.Delegation.Certificates (PoolDistr (..))
import           Shelley.Spec.Ledger.Keys (GenDelegs (..), hashKey, vKey)
import           Shelley.Spec.Ledger.LedgerState (pattern ActiveSlot, pattern EpochState,
                     pattern NewEpochState, esLState, esPp, getGKeys, nesEL, nesEs, nesOsched,
                     nesPd, overlaySchedule, _delegationState, _dstate, _genDelegs, _reserves)
import           Shelley.Spec.Ledger.OCert (KESPeriod (..), currentIssueNo, kesPeriod)
import           Shelley.Spec.Ledger.PParams (PParams' (_activeSlotCoeff), activeSlotVal)
import           Shelley.Spec.Ledger.Slot (EpochNo (..), SlotNo (..))
import           Shelley.Spec.Ledger.STS.Chain (chainEpochNonce, chainLastAppliedBlock, chainNes,
                     chainOCertIssue)
import           Shelley.Spec.Ledger.STS.Ledgers (LedgersEnv (..))
import           Shelley.Spec.Ledger.STS.Ocert (pattern OCertEnv)
import           Shelley.Spec.Ledger.STS.Tick (TickEnv (..))

import           Test.Shelley.Spec.Ledger.ConcreteCryptoTypes (Block, ChainState,
                     GenKeyHash, LEDGERS, OBftSlot, TICK)
import           Test.Shelley.Spec.Ledger.Generator.Core (AllPoolKeys (..), GenEnv(..), KeySpace(..), NatNonce (..),
                     genNatural, getKESPeriodRenewalNo, mkBlock, mkOCert)
import           Test.Shelley.Spec.Ledger.Generator.Trace.Ledger ()
import           Test.Shelley.Spec.Ledger.Utils (maxKESIterations, runShelleyBase,
                     unsafeMkUnitInterval)

nextCoreNode
  :: Map SlotNo OBftSlot
  -> Map SlotNo OBftSlot
  -> SlotNo
  -> (SlotNo, GenKeyHash)
nextCoreNode os nextOs s =
  let getNextOSlot os' =
        let (_, nextSlots) = Map.split s os'
        in listToMaybe [(slot, k) | (slot, ActiveSlot k) <- Map.toAscList nextSlots]
  in
  case getNextOSlot os of
    Nothing -> -- there are no more active overlay slots this epoch
      case getNextOSlot nextOs of
        Nothing -> error "TODO - handle d=0"
        Just n -> n
    Just n -> n

-- | Find the next active Praos slot.
getPraosSlot
  :: SlotNo
  -> SlotNo
  -> Map SlotNo OBftSlot
  -> Map SlotNo OBftSlot
  -> Maybe SlotNo
getPraosSlot start tooFar os nos =
  let schedules = os `Map.union` nos
  in List.find (not . (`Map.member` schedules)) [start .. tooFar-1]

genBlock
  :: GenEnv
  -> SlotNo
  -> ChainState
  -> Gen Block
genBlock ge@(GenEnv KeySpace_ {ksCoreNodes, ksKeyPairsByStakeHash, ksVRFKeyPairsByHash } _)
          sNow chainSt = do
  let os = (nesOsched . chainNes) chainSt
      dpstate = (_delegationState . esLState . nesEs . chainNes) chainSt
      pp = (esPp . nesEs . chainNes) chainSt
      (EpochNo e) = (nesEL . chainNes) chainSt
      (GenDelegs cores) = (_genDelegs . _dstate) dpstate
      nextOs = runShelleyBase $ overlaySchedule
        (EpochNo $ e + 1) (Map.keysSet cores) pp
      (nextOSlot, gkey) = nextCoreNode os nextOs slot

  {- Our slot selection strategy uses the overlay schedule.
   - Above we calculated the next available core node slot
   - Note that we will need to do something different
   - when we start allowing d=0, and there is no such next core slot.
   - If there are no current stake pools, as determined by the pd mapping
   - (pools to relative stake), then we take the next core node slot.
   - Note that the mapping of registered stake pools is different, ie
   - the one in PState, since news pools will not yet be a part of
   - a snapshot and are therefore not yet ready to make blocks.
   - Otherwise, if there are active pools, we generate a small increase
   - from the current slot, and then take the first slot from this point
   - that is either available for Praos or is a core node slot.
   -}

  lookForPraosStart <- genSlotIncrease
  let poolParams = (Map.toList . Map.filter ((> 0) . fst) . unPoolDistr . nesPd . chainNes) chainSt
  poolParams' <- take 1 <$> QC.shuffle poolParams
  let (nextSlot, poolStake, keys) = case poolParams' of
        []       -> (nextOSlot, 0, gkeys gkey)
        (pkh, (stake, vrfkey)):_ -> case getPraosSlot lookForPraosStart nextOSlot os nextOs of
                      Nothing -> (nextOSlot, 0, gkeys gkey)
                      Just ps -> let apks = AllPoolKeys
                                       { cold = (ksKeyPairsByStakeHash Map.! pkh)
                                       , vrf  = (ksVRFKeyPairsByHash Map.! vrfkey)
                                       , hot  = (hot $ gkeys gkey)
                                                -- TODO @jc - don't use the genesis hot key
                                       , hk   = pkh
                                       }
                                 in (ps, stake, apks)

  if nextSlot > sNow
    then QC.discard
    else do

    let kp@(KESPeriod kesPeriod_) = runShelleyBase (kesPeriod $ nextSlot)
        cs = chainOCertIssue chainSt

        -- ran genDelegs
        genDelegationKeys = range cores

        n' = currentIssueNo
             (OCertEnv (dom poolParams) genDelegationKeys)
             cs
             ((hashKey . vKey . cold) keys)

        m = getKESPeriodRenewalNo keys kp

        hotKeys = drop (fromIntegral m) (hot keys)
        keys' = keys { hot = hotKeys }
        oCert =
          case n' of
            Nothing -> error "no issue number available"
            Just _ ->
              mkOCert keys' (fromIntegral m) ((fst . head) hotKeys)

    let nes  = chainNes chainSt
        nes' = runShelleyBase $ (applySTS @TICK $ TRC (TickEnv (getGKeys nes), nes, nextSlot))

    case nes' of
      Left _ -> QC.discard
      Right _nes' -> do
        let NewEpochState _ _ _ es _ _ _ = _nes'
            EpochState acnt _ ls _ pp' _   = es
        mkBlock
          <$> pure hashheader
          <*> pure keys'
          <*> toList <$> genTxs pp' (_reserves acnt) ls nextSlot
          <*> pure nextSlot
          <*> pure (block + 1)
          <*> pure (chainEpochNonce chainSt)
          <*> genBlockNonce
          <*> genPraosLeader poolStake pp'
          <*> pure kesPeriod_
          <*> pure (fromIntegral (m * fromIntegral maxKESIterations))
          <*> pure oCert
  where
    (block, slot, hashheader) = case chainLastAppliedBlock chainSt of
      Origin -> error "block generator does not support from Origin"
      At (LastAppliedBlock b s hh) -> (b, s, hh)
    ledgerSt = (esLState . nesEs . chainNes) chainSt
    (GenDelegs genesisDelegs) = (_genDelegs . _dstate . _delegationState) ledgerSt

    origIssuerKeys h = case List.find (\(k, _) -> (hashKey . vKey) k == h) ksCoreNodes of
                         Nothing -> error "couldn't find corresponding core node key"
                         Just k  -> snd k
    gkeys gkey =
        case Map.lookup gkey genesisDelegs of
          Nothing ->
            error "genBlock: NoGenesisStakingOVERLAY"
          Just gKeyHash ->
            -- if GenesisDelegate certs changed a delegation to a new key
            case Map.lookup gKeyHash ksKeyPairsByStakeHash of
              Nothing ->
                -- then we use the original keys (which have not been changed by a genesis delegation)
                origIssuerKeys gkey
              Just updatedCold ->
                -- if we find the pre-hashed key in keysByStakeHash, we use it instead of the original cold key
                (origIssuerKeys gkey) {cold = updatedCold, hk = (hashKey . vKey) updatedCold}

    genPraosLeader stake pp =
      if stake >= 0 && stake <= 1 then do
        -- we subtract one from the numerator for a non-zero stake e.g. for a
        -- stake of 3/20, we would go with 2/20 and then divide by a random
        -- integer in [1,10]. This value is guaranteed to be below the ϕ
        -- function for the VRF value comparison and generates a valid leader
        -- value for Praos.
        let stake' = if stake > 0
              then (numerator stake - 1) % denominator stake
              else stake
        n <- genNatural 1 10
        pure (unsafeMkUnitInterval ((stake' / fromIntegral n)
                                    * ((intervalValue . activeSlotVal . _activeSlotCoeff) pp)))
      else
        error "stake not in [0; 1]"

    -- we assume small gaps in slot numbers
    genSlotIncrease = SlotNo . (lastSlotNo +) <$> QC.choose (1, 5)
    lastSlotNo = unSlotNo slot

    genBlockNonce = NatNonce <$> genNatural 1 100

    genTxs pp reserves ls s = do
      let ledgerEnv = LedgersEnv s pp reserves

      sigGen @LEDGERS ge ledgerEnv ls