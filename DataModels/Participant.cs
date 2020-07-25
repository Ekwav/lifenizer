using System.Collections.Generic;

namespace lifenizer.DataModels
{
    public class Participant 
    {
        /// <summary>
        /// Display name of this Participant
        /// </summary>
        /// <value></value>
        public string Name {get;set;}
        /// <summary>
        /// Identifiers connected to this person
        /// </summary>
        /// <value></value>
        public List<Identifier> Ids {get;set;}
        /// <summary>
        /// Wich relations does this <see cref="Participant"/> have
        /// </summary>
        /// <value></value>
        public List<Relation> Relations {get;set;}
    }

}