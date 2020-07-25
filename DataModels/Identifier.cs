namespace lifenizer.DataModels
{
    public class Identifier
    {
        /// <summary>
        /// The value of this identifier such as "mark@example.com"
        /// </summary>
        public string Value {get;set;}
        /// <summary>
        /// The confidence that his identifier coresponds to a sepefic person
        /// </summary>
        public int Confidence {get;set;}
    }

}