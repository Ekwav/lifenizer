using System;

namespace lifenizer.DataModels
{
    public class Relation
    {
        public string Identifier {get;set;}
        public RelationType Type {get;set;}
        public DateTime TimeStamp  {get;set;}
        public string Source {get;set;}
    }
}