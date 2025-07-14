#!/usr/bin/env node

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ABI 파일 로드
function loadABI() {
  const abiPath = path.join(
    __dirname,
    "../artifacts/contracts/core/BaseVolOneDay.sol/BaseVolOneDay.json",
  );
  const abiFile = JSON.parse(fs.readFileSync(abiPath, "utf8"));
  return abiFile.abi;
}

// 에러 데이터 파싱 함수
function parseErrorData(data) {
  try {
    const BaseVolOneDayAbi = loadABI();
    const iface = new ethers.Interface(BaseVolOneDayAbi);
    const decoded = iface.parseError(data);
    return decoded?.name || data;
  } catch (error) {
    return data;
  }
}

// 메인 실행 함수
async function main() {
  // 명령행 인수에서 data 가져오기
  const data = process.argv[2];

  if (!data) {
    console.log("Usage: node find-error.js <error_data>");
    console.log("Example: node find-error.js 0x1234abcd...");
    process.exit(1);
  }

  console.log("Input data:", data);

  const result = parseErrorData(data);

  if (result === data) {
    console.log("Result: Could not decode error (unknown error or invalid data)");
  } else {
    console.log("Result: Error name -", result);
  }
}

// 스크립트가 직접 실행될 때만 main 함수 호출
if (require.main === module) {
  main().catch((error) => {
    console.error("Error:", error.message);
    process.exit(1);
  });
}

module.exports = { parseErrorData };
