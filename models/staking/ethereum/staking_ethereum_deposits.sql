{{ config(
    tags = ['dunesql'],
    alias = alias('deposits'),
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_time', 'tx_hash', 'deposit_index'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "sector",
                                "staking",
                                \'["hildobby"]\') }}')
}}

WITH deposit_events AS (
    SELECT d.evt_block_time AS block_time
    , d.evt_block_number AS block_number
    , d.evt_index
    , d.evt_tx_hash AS tx_hash
    , bytearray_to_bigint(reverse(d.amount))/1e9 AS amount
    , d.contract_address
    , bytearray_to_bigint(reverse(d.index)) AS deposit_index
    , d.pubkey
    , d.signature
    , CASE WHEN bytearray_position(d.withdrawal_credentials, from_hex('0x01')) = 1 THEN from_hex('0x01') ELSE from_hex('0x00') END AS withdrawal_credentials_type
    , CASE WHEN bytearray_position(d.withdrawal_credentials, from_hex('0x01')) = 1 THEN bytearray_substring(d.withdrawal_credentials, 13)
        ELSE NULL
        END AS withdrawal_address
    , d.withdrawal_credentials
    , ROW_NUMBER() OVER (PARTITION BY d.evt_block_number, d.evt_tx_hash, from_big_endian_64(reverse(d.amount)) ORDER BY d.evt_index) AS table_merging_deposits_id
    FROM {{ source('eth2_ethereum', 'DepositContract_evt_DepositEvent') }} d
    {% if not is_incremental() %}
    WHERE d.evt_block_time >= TIMESTAMP '2020-10-14'
    {% endif %}
    {% if is_incremental() %}
    WHERE d.evt_block_time >= date_trunc('day', now() - interval '7' day)
    {% endif %}
    )
    
, traces AS (
    SELECT t.block_number
    , t.tx_hash AS tx_hash
    , t.value / POWER(10, 18) AS amount
    , t."from" AS depositor_address
    , ROW_NUMBER() OVER (PARTITION BY t.block_number, t.tx_hash, t.value ORDER BY t.trace_address) AS table_merging_traces_id
    FROM {{ source('ethereum', 'traces') }} t
    WHERE t.to = 0x00000000219ab540356cbb839cbe05303d7705fa
    AND (call_type NOT IN ('delegatecall', 'callcode', 'staticcall') OR call_type IS NULL)
    AND t.value > UINT256 '0'
    AND success
    {% if not is_incremental() %}
    AND t.block_time >= TIMESTAMP '2020-10-14'
    {% endif %}
    {% if is_incremental() %}
    AND t.block_time >= date_trunc('day', now() - interval '7' day)
    {% endif %}
    )
    
SELECT d.block_time
, d.block_number
, d.amount AS amount_staked
, ett.depositor_address
, ete.entity
, ete.entity_unique_name
, ete.category AS entity_category
, d.tx_hash
, et."from" AS tx_from
, d.deposit_index
, d.pubkey
, d.signature
, d.withdrawal_credentials_type
, d.withdrawal_address
, d.withdrawal_credentials
, d.evt_index
FROM deposit_events d
INNER JOIN {{ source('ethereum', 'transactions') }} et ON et.block_number=d.block_number
    AND et.hash=d.tx_hash
    {% if not is_incremental() %}
    AND et.block_time >= TIMESTAMP '2020-10-14'
    {% endif %}
    {% if is_incremental() %}
    AND et.block_time >= date_trunc('day', now() - interval '7' day)
    {% endif %}
INNER JOIN traces ett ON ett.block_number=d.block_number
    AND ett.tx_hash=d.tx_hash
    AND ett.amount=d.amount
    AND ett.table_merging_traces_id=d.table_merging_deposits_id
LEFT JOIN {{ ref('staking_ethereum_entities')}} ete
    ON ett.depositor_address=ete.address