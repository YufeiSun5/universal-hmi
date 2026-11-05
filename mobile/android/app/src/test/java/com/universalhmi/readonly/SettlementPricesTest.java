package com.universalhmi.readonly;
import static org.junit.Assert.*;
import org.junit.Test;

public class SettlementPricesTest {
 @Test public void persistsPerAccountAndServerAndClears() throws Exception {
  IdentitySessionTest.Memory storage=new IdentitySessionTest.Memory();
  SettlementPrices prices=new SettlementPrices(storage);
  prices.request("action=save&username=alice&price=25.120001");
  prices.request("action=save&username=bob&price=0");
  prices=new SettlementPrices(storage);
  assertEquals("25.120001",prices.request("action=load&username=alice"));
  assertEquals("0",prices.request("action=load&username=bob"));
  assertEquals("",new SettlementPrices(new IdentitySessionTest.Memory()).request("action=load&username=alice"));
  prices.request("action=save&username=alice&price=");
  assertEquals("",new SettlementPrices(storage).request("action=load&username=alice"));
  assertEquals("0",prices.request("action=load&username=bob"));
  for(String invalid:new String[]{"-1","NaN","1e6","1.1234567"}) {
   try { prices.request("action=save&username=bob&price="+invalid);fail("invalid price accepted"); }
   catch(IllegalArgumentException expected) { }
  }
 }
 @Test public void failedWritePreservesPreviousValue() throws Exception {
  SupplierCookies.Persistence broken=new SupplierCookies.Persistence() {
   public String load() {return "alice=7";}
   public void save(String value) throws Exception {throw new java.io.IOException();}
  };
  SettlementPrices prices=new SettlementPrices(broken);
  try {prices.request("action=save&username=alice&price=9");fail();} catch(java.io.IOException expected) { }
  assertEquals("7",prices.request("action=load&username=alice"));
 }
}
