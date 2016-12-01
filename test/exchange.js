var async = require('async');
var assert = require('assert');
var BigNumber = require('bignumber.js');


contract('Exchange', (accounts) => {

  // Solidity constants
  const ether = new BigNumber(Math.pow(10,18));

  // Contract constants
  const PREMINED_PRECISION = new BigNumber(Math.pow(10,8));
  const PREMINED_AMOUNT = new BigNumber(Math.pow(10,10));

  // Test constants
  const INITIAL_OFFER_ID = 0;
  const OWNER = accounts[0];
  const NOT_OWNER = accounts[1];
  const NUM_OFFERS = 3;
  const ALLOWANCE_AMOUNT = PREMINED_AMOUNT / 10;

  // Test globals
  let contract;
  let contractAddress;
  let etherTokenContract;
  let etherTokenAddress;
  let bitcoinTokenContract;
  let bitcoinTokenAddress;
  let testCases;
  let lastOfferId = 0;


  before('Check accounts', (done) => {
    assert.equal(accounts.length, 10);
    done();
  });

  it('Deploy smart contract', (done) => {
    Exchange.new().then((result) => {
      contract = result;
      contractAddress = contract.address;
      return contract.lastOfferId();
    }).then((result) => {
      assert.equal(result.toNumber(), INITIAL_OFFER_ID)
      return EtherToken.new();
    }).then((result) => {
      etherTokenContract = result;
      etherTokenAddress = etherTokenContract.address;
      return BitcoinToken.new({ from: OWNER }
      );
    }).then((result) => {
      bitcoinTokenContract = result;
      bitcoinTokenAddress = bitcoinTokenContract.address;
      return bitcoinTokenContract.totalSupply({ from: OWNER });
    }).then((result) => {
      assert.equal(result.toNumber(), PREMINED_AMOUNT.toNumber());
      return bitcoinTokenContract.balanceOf(OWNER);
    }).then((result) => {
      assert.equal(result.toNumber(), PREMINED_AMOUNT.toNumber());
      done();
    });
  });

  // Assuming 1 BTT == 0.01115 EtherToken, reduce offers by 0.1 on each order
  it('Set up test cases', (done) => {
    testCases = [];
    for (let i = 0; i < NUM_OFFERS; i++) {
      testCases.push(
        {
          sell_how_much: 0.01115 * (1 - i*0.1) * PREMINED_PRECISION,
          sell_which_token: bitcoinTokenAddress,
          buy_how_much: 1 * ether,
          buy_which_token: etherTokenAddress,
          id: i + 1,
          owner: OWNER,
          active: true,
        }
      );
    }
    done();
  });

  it('OWNER approves exchange to hold funds of bitcoinTokenContract', (done) => {
    bitcoinTokenContract.approve(contractAddress, ALLOWANCE_AMOUNT, { from: OWNER }
    ).then((result) => {
      return bitcoinTokenContract.allowance(OWNER, contractAddress);
    }).then((result) => {
      assert.equal(result, ALLOWANCE_AMOUNT);
      done();
    });
  });

  it('Create one side of the orderbook', (done) => {
    async.mapSeries(
      testCases,
      (testCase, callbackMap) => {
        contract.offer(
          testCase.sell_how_much,
          testCase.sell_which_token,
          testCase.buy_how_much,
          testCase.buy_which_token,
          { from: OWNER }
        ).then((result) => {
          testCase.txHash = result;
          callbackMap(null, testCase);
        });
      },
      (err, results) => {
        testCases = results;
        done();
      }
    );
  });

  it('Check if orders created', (done) => {
    contract.lastOfferId({ from: OWNER }
    ).then((result) => {
      lastOfferId = result.toNumber();
      assert.equal(lastOfferId, NUM_OFFERS);
      done();
    });
  });

  it('Check orders information', (done) => {
    async.mapSeries(
      testCases,
      (testCase, callbackMap) => {
        contract.offers(testCase.id
        ).then((result) => {
          let data = result;
          const idx = testCase.id.toString();
          const [sellHowMuch, sellWhichTokenAddress, buyHowMuch, buyWhichTokenAddress, owner, active] = data;
          console.log(testCase.id, sellHowMuch.toNumber(), buyHowMuch.toNumber());
          callbackMap(null, testCase);
        });
      },
      (err, results) => {
        testCases = results;
        done();
      }
    );
  });

  it('Cancel one side of the orderbook', (done) => {
    async.mapSeries(
      testCases,
      (testCase, callbackMap) => {
        contract.cancel(testCase.id, { from: OWNER }
        ).then((result) => {
          testCase.txHash = result;
          callbackMap(null, testCase);
        });
      },
      (err, results) => {
        testCases = results;
        done();
      }
    );
  });

  it('Check orders information', (done) => {
    async.mapSeries(
      testCases,
      (testCase, callbackMap) => {
        contract.offers(testCase.id
        ).then((result) => {
          let data = result;
          const idx = testCase.id.toString();
          const [sellHowMuch, sellWhichTokenAddress, buyHowMuch, buyWhichTokenAddress, owner, active] = data;
          console.log(testCase.id, sellHowMuch.toNumber(), buyHowMuch.toNumber());
          callbackMap(null, testCase);
        });
      },
      (err, results) => {
        testCases = results;
        done();
      }
    );
  });

});