{{ config(tags=['dunesql'],
    schema = 'pancakeswap_v2_base',
    alias = alias('amm_trades'),
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index'],
    post_hook='{{ expose_spells(\'["base"]\',
                                "project",
                                "pancakeswap_v2",
                                \'["chef_seaweed"]\') }}'
    )
}}

{% set project_start_date = '2023-08-30' %}

WITH dexs AS
(
    -- PancakeSwap v2 on base
    SELECT
        t.evt_block_time                                                                AS block_time,
        t.to                                                                            AS taker,
        CAST(NULL AS VARBINARY)                                                         AS maker,
        CASE WHEN amount0Out = UINT256 '0' THEN amount1Out ELSE amount0Out END          AS token_bought_amount_raw,
        CASE WHEN amount0In = UINT256 '0' OR amount1Out = UINT256 '0' THEN amount1In ELSE amount0In END AS token_sold_amount_raw,
        NULL                                                            AS amount_usd,
        CASE WHEN amount0Out = UINT256 '0' THEN f.token1 ELSE f.token0 END                      AS token_bought_address,
        CASE WHEN amount0In = UINT256 '0' OR amount1Out = UINT256 '0' THEN f.token1 ELSE f.token0 END   AS token_sold_address,
        t.contract_address                                                              AS project_contract_address,
        t.evt_tx_hash                                                                   AS tx_hash,
        t.evt_index
    FROM
        {{ source('pancakeswap_v2_base', 'PancakePair_evt_Swap') }} t
    INNER JOIN
        {{ source('pancakeswap_v2_base', 'PancakeFactory_evt_PairCreated') }} f
        ON t.contract_address = f.pair
    {% if is_incremental() %}
    WHERE t.evt_block_time >= date_trunc('day', now() - interval '7' day)
    {% endif %}
)

SELECT
    'base'                                                   AS blockchain
     , 'pancakeswap'                                             AS project
     , '2'                                                       AS version
     , TRY_CAST(date_trunc('DAY', dexs.block_time) AS date)      AS block_date
     , CAST(date_trunc('month', dexs.block_time) AS date)        AS block_month
     , dexs.block_time
     , erc20a.symbol                                             AS token_bought_symbol
     , erc20b.symbol                                             AS token_sold_symbol
     , case
           when lower(erc20a.symbol) > lower(erc20b.symbol) then concat(erc20b.symbol, '-', erc20a.symbol)
           else concat(erc20a.symbol, '-', erc20b.symbol)
       end                                                       AS token_pair
     , dexs.token_bought_amount_raw / power(10, erc20a.decimals) AS token_bought_amount
     , dexs.token_sold_amount_raw / power(10, erc20b.decimals)   AS token_sold_amount
     , dexs.token_bought_amount_raw  AS token_bought_amount_raw
     , dexs.token_sold_amount_raw  AS token_sold_amount_raw
     , coalesce(
        dexs.amount_usd
        , (dexs.token_bought_amount_raw / power(10, p_bought.decimals)) * p_bought.price
        , (dexs.token_sold_amount_raw / power(10, p_sold.decimals)) * p_sold.price
        )                                                        AS amount_usd
     , dexs.token_bought_address
     , dexs.token_sold_address
     , coalesce(dexs.taker, tx."from")                             AS taker -- subqueries rely on this COALESCE to avoid redundant joins with the transactions table
     , dexs.maker
     , dexs.project_contract_address
     , dexs.tx_hash
     , tx."from"                                                   AS tx_from
     , tx.to                                                     AS tx_to
     , dexs.evt_index
FROM dexs
INNER JOIN {{ source('base', 'transactions') }} tx
    ON tx.hash = dexs.tx_hash
    {% if not is_incremental() %}
    AND tx.block_time >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND tx.block_time >= date_trunc('day', now() - interval '7' day)
    {% endif %}
LEFT JOIN {{ ref('tokens_erc20') }} erc20a
    ON erc20a.contract_address = dexs.token_bought_address
    AND erc20a.blockchain = 'base'
LEFT JOIN {{ ref('tokens_erc20') }} erc20b
    ON erc20b.contract_address = dexs.token_sold_address
    AND erc20b.blockchain = 'base'
LEFT JOIN {{ source('prices', 'usd') }} p_bought
    ON p_bought.minute = date_trunc('minute', dexs.block_time)
    AND p_bought.contract_address = dexs.token_bought_address
    AND p_bought.blockchain = 'base'
    {% if not is_incremental() %}
    AND p_bought.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_bought.minute >= date_trunc('day', now() - interval '7' day)
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_sold
    ON p_sold.minute = date_trunc('minute', dexs.block_time)
    AND p_sold.contract_address = dexs.token_sold_address
    AND p_sold.blockchain = 'base'
    {% if not is_incremental() %}
    AND p_sold.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_sold.minute >= date_trunc('day', now() - interval '7' day)
    {% endif %}

